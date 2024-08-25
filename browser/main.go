package main

import (
	"context"
	"database/sql"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/evertras/bubble-table/table"
	"github.com/mattn/go-sqlite3"
	"github.com/spf13/pflag"

	_ "embed"
)

//go:embed histdb.lua
var histDBSource string

//go:embed lua-vtable.so
var vtableExtension []byte

var (
	defaultStyle       = lipgloss.NewStyle().AlignHorizontal(lipgloss.Left)
	headerStyle        = lipgloss.NewStyle().Bold(true)
	highlightStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#ff87d7")).Bold(true)
	failedCommandStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#ff0000")).Bold(true)
)

var toggleWorkingDirectoryKey = key.NewBinding(
	key.WithKeys("f2"),
	key.WithHelp("f2", "Toggle working directory column"),
)

var toggleTimestampKey = key.NewBinding(
	key.WithKeys("f3"),
	key.WithHelp("f3", "Toggle timestamp column"),
)

var toggleSessionIDKey = key.NewBinding(
	key.WithKeys("f4"),
	key.WithHelp("f4", "Toggle session ID column"),
)

var toggleFailedCommandsKey = key.NewBinding(
	key.WithKeys("f5"),
	key.WithHelp("f5", "Toggle failed commands"),
)

var toggleLocalCommandsKey = key.NewBinding(
	key.WithKeys("f6"),
	key.WithHelp("f6", "Toggle local/global commands"),
)

var columnWidths = map[string]int{
	"timestamp":  20, // based on YYYY-MM-DD HH:MM:SS, with a little padding
	"session_id": 10, // this could be 6 based on PIDs on my machine, but bumped to len("session_id")
	"cwd":        70, // based on my history
}

type model struct {
	db    *sql.DB
	input textinput.Model
	table table.Model

	selection string

	showTimestamp        bool
	showWorkingDirectory bool
	showSessionID        bool

	showFailedCommands bool
	showGlobalCommands bool

	horizonTimestamp time.Time
	sessionID        string
}

func (m *model) Init() tea.Cmd {
	return tea.Batch(
		m.input.Focus(),
		m.table.Init(),
	)
}

func (m *model) getRowsFromQuery(sql string, args ...any) ([]table.Column, []table.Row, error) {
	slog.Debug("running SQL", "query", sql, "args", fmt.Sprintf("%#v", args))
	startTime := time.Now()
	rows, err := m.db.Query(sql, args...)
	if err != nil {
		return nil, nil, err
	}

	tableRows := make([]table.Row, 0)

	columns, err := rows.Columns()
	if err != nil {
		return nil, nil, err
	}

	tableColumns := make([]table.Column, 0, len(columns))

	for _, columnName := range columns {
		if columnName == "exit_status" {
			continue
		}

		columnWidth := columnWidths[columnName]
		if columnWidth == 0 {
			columnWidth = 20
		}

		var tableColumn table.Column

		if columnName == "entry" {
			tableColumn = table.NewFlexColumn(columnName, columnName, 1)
		} else {
			tableColumn = table.NewColumn(columnName, columnName, columnWidth)
		}

		tableColumns = append(tableColumns, tableColumn)
	}

	rowValues := make([]string, len(columns))
	scanPointers := make([]any, len(columns))
	for i := range rowValues {
		scanPointers[i] = &rowValues[i]
	}

	for rows.Next() {
		err := rows.Scan(scanPointers...)
		if err != nil {
			return nil, nil, err
		}

		rowData := make(map[string]any)

		for i, columnName := range columns {
			rowData[columnName] = rowValues[i]
		}
		tableRows = append(tableRows, table.NewRow(rowData))
	}

	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	slog.Debug("# rows", "row_count", len(tableRows), "duration", time.Since(startTime))

	return tableColumns, tableRows, err
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	defer func() {
		if err := recover(); err != nil {
			slog.Error("panic", "error", err, "stack_trace", string(debug.Stack()))
		}
	}()

	newModel := *m

	var tableCmd tea.Cmd
	var inputCmd tea.Cmd

	columnsChanged := false

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		newModel.table = newModel.table.WithTargetWidth(msg.Width)
		columnsChanged = true
	case tea.KeyMsg:
		slog.Debug("got keypress", "key", msg.String())
		switch msg.String() {
		case "ctrl+c", "esc":
			return &newModel, tea.Quit
		case "ctrl+j", "down":
			newModel.table, tableCmd = newModel.table.Update(tea.KeyMsg{Type: tea.KeyDown})
		case "ctrl+k", "up":
			newModel.table, tableCmd = newModel.table.Update(tea.KeyMsg{Type: tea.KeyUp})
		case "enter":
			selectedRow := newModel.table.HighlightedRow().Data
			rowAttrs := make([]slog.Attr, 0, len(selectedRow))
			for k, v := range selectedRow {
				rowAttrs = append(rowAttrs, slog.Attr{Key: k, Value: slog.AnyValue(v)})
			}
			slog.LogAttrs(context.TODO(), slog.LevelInfo, "selected row", rowAttrs...)
			newModel.selection = selectedRow["entry"].(string)
			return &newModel, tea.Quit
		}

		// XXX merge these two (put ctrl+c into a keymap)
		switch {
		case key.Matches(msg, toggleWorkingDirectoryKey):
			slog.Info("toggling working directory display")
			newModel.showWorkingDirectory = !newModel.showWorkingDirectory
			columnsChanged = true
		case key.Matches(msg, toggleTimestampKey):
			slog.Info("toggling timestamp display")
			newModel.showTimestamp = !newModel.showTimestamp
			columnsChanged = true
		case key.Matches(msg, toggleSessionIDKey):
			slog.Info("toggling session ID display")
			newModel.showSessionID = !newModel.showSessionID
			columnsChanged = true
		case key.Matches(msg, toggleFailedCommandsKey):
			slog.Info("toggling failed commands display")
			newModel.showFailedCommands = !newModel.showFailedCommands
			columnsChanged = true
		case key.Matches(msg, toggleLocalCommandsKey):
			if newModel.horizonTimestamp.IsZero() {
				slog.Warn("horizon timestamp not set, not toggling local/global commands display")
			} else {
				slog.Info("toggling local/global commands display")
				newModel.showGlobalCommands = !newModel.showGlobalCommands
				columnsChanged = true
			}
		}
	}

	previousQuery := newModel.input.Value()

	if _, isKeyMsg := msg.(tea.KeyMsg); !isKeyMsg {
		newModel.table, tableCmd = newModel.table.Update(msg)
	}

	newModel.input, inputCmd = newModel.input.Update(msg)

	if query := newModel.input.Value(); query != previousQuery || columnsChanged {
		selectClauseColumns := make([]string, 0)

		if newModel.showTimestamp {
			selectClauseColumns = append(selectClauseColumns, "timestamp")
		}
		if newModel.showSessionID {
			selectClauseColumns = append(selectClauseColumns, "session_id")
		}
		if newModel.showWorkingDirectory {
			selectClauseColumns = append(selectClauseColumns, "cwd")
		}

		selectClauseColumns = append(selectClauseColumns, "entry")

		selectClause := strings.Join(selectClauseColumns, ", ")

		whereClausePredicates := []string{
			"timestamp IS NOT NULL",
		}
		queryParams := make([]any, 0)

		if query != "" {
			whereClausePredicates = append(whereClausePredicates, "entry MATCH ?")
			queryParams = append(queryParams, query)
		}

		if !newModel.showFailedCommands {
			whereClausePredicates = append(whereClausePredicates, "exit_status IN (0, 148)")
		}

		if !newModel.showGlobalCommands && !newModel.horizonTimestamp.IsZero() {
			whereClausePredicates = append(whereClausePredicates, "(raw_timestamp <= ? OR session_id = ?)")
			queryParams = append(queryParams, newModel.horizonTimestamp.Unix())
			queryParams = append(queryParams, newModel.sessionID)
		}

		whereClause := strings.Join(whereClausePredicates, " AND ")

		columns, rows, err := newModel.getRowsFromQuery(fmt.Sprintf("SELECT %s, COALESCE(exit_status, '') AS exit_status FROM h WHERE %s ORDER BY timestamp DESC LIMIT 100", selectClause, whereClause), queryParams...)
		if err != nil {
			panic(err)
		}

		newModel.table = newModel.table.WithColumns(columns)
		newModel.table = newModel.table.WithRows(rows)
	}

	return &newModel, tea.Batch(tableCmd, inputCmd)
}

func (m *model) View() string {
	return m.input.View() + "\n" + m.table.View() + "\n"
}

func main() {
	horizonTimestamp := uint64(0)
	sessionID := ""
	logFilename := ""
	logLevel := "info"
	logFormat := "text"

	pflag.Uint64Var(&horizonTimestamp, "horizon-timestamp", 0, "The maximum timestamp to consider for results outside of this session")
	pflag.StringVar(&sessionID, "session-id", strconv.Itoa(os.Getppid()), "The current session ID")
	pflag.StringVar(&logFilename, "log-filename", "", "The filename to log to")
	pflag.StringVar(&logLevel, "log-level", "info", "The log level to log at")
	pflag.StringVar(&logFormat, "log-format", logFormat, "The log format to log in (text, json)")
	pflag.Parse()

	var buildLogHandler func(io.Writer, *slog.HandlerOptions) slog.Handler = func(w io.Writer, opts *slog.HandlerOptions) slog.Handler {
		return slog.NewTextHandler(w, opts)
	}

	if logFormat == "json" {
		buildLogHandler = func(w io.Writer, opts *slog.HandlerOptions) slog.Handler {
			return slog.NewJSONHandler(w, opts)
		}
	}

	if logFilename != "" {
		f, err := tea.LogToFile(logFilename, logLevel)
		if err != nil {
			panic(err)
		}

		defer f.Close()

		var level slog.Level

		switch logLevel {
		case "debug":
			level = slog.LevelDebug
		case "info":
			level = slog.LevelInfo
		case "warn":
			level = slog.LevelWarn
		case "error":
			level = slog.LevelError
		default:
			panic("Invalid log level")
		}

		if logFormat == "json" {
			slog.SetDefault(slog.New(buildLogHandler(f, &slog.HandlerOptions{
				Level: level,
			})))
		} else {
			slog.SetDefault(slog.New(buildLogHandler(f, &slog.HandlerOptions{
				Level: level,
			})))
		}
	} else {
		slog.SetDefault(slog.New(buildLogHandler(io.Discard, nil)))
	}

	err := os.WriteFile("/home/rob/.cache/lua-vtable.so", vtableExtension, 0o700)
	if err != nil {
		panic(err)
	}

	sql.Register("sqlite3-histdb-extensions", &sqlite3.SQLiteDriver{
		Extensions: []string{
			"/home/rob/.cache/lua-vtable.so",
		},
	})

	st, err := os.Stat("/home/rob/.cache/histdb.db")
	if err != nil {
		panic(err)
	}

	// if the rollup database is too old, just run histdb to refresh it
	if time.Now().Format(time.DateOnly) != st.ModTime().Format(time.DateOnly) {
		err := exec.Command("histdb", ".schema").Run()
		if err != nil {
			panic(err)
		}
	}

	// XXX probably want to do the whole roll-up and ATTACH thing too?
	db, err := sql.Open("sqlite3-histdb-extensions", "/home/rob/.cache/histdb.db")
	if err != nil {
		panic(err)
	}
	defer db.Close()

	databaseDir := "/home/rob/.zsh_history.d"
	todayDatabaseBasename := time.Now().Format(time.DateOnly) + ".db"

	_, err = db.Exec(fmt.Sprintf("ATTACH DATABASE '%s/%s' AS today_db", databaseDir, todayDatabaseBasename))
	if err != nil {
		panic(err)
	}

	_, err = db.Exec(`
CREATE TABLE IF NOT EXISTS today_db.history (
    hostname,
    session_id, -- shell PID
    timestamp integer not null,
    tz_offset integer,
    history_id, -- $HISTCMD
    cwd,
    entry,
    duration,
    exit_status
);
	`)
	if err != nil {
		panic(err)
	}

	_, err = db.Exec("SELECT lua_create_module_from_source(?)", histDBSource)
	if err != nil {
		panic(err)
	}

	_, err = db.Exec("CREATE TEMPORARY VIEW history AS SELECT rowid, * FROM history_before_today")
	if err != nil {
		panic(err)
	}

	lipgloss.SetDefaultRenderer(lipgloss.NewRenderer(os.Stderr))

	input := textinput.New()

	t := table.New(nil).
		WithPageSize(20). // only show the top 20 rows
		Border(table.Border{
			// XXX these values feel super-duper magical and I would like to figure
			//     out if there's a better way, but this'll work for now
			RightJunction: " ",
			BottomRight:   " ",
			InnerDivider:  " ",
		}).                          // don't show any borders, but space out cells
		Focused(true).               // needed to display row highlights
		WithFooterVisibility(false). // don't show the paging widget
		WithMultiline(true).
		// styling
		HeaderStyle(headerStyle).
		WithBaseStyle(defaultStyle).
		WithRowStyleFunc(func(in table.RowStyleFuncInput) lipgloss.Style {
			if in.IsHighlighted {
				return highlightStyle
			}
			exitStatus := in.Row.Data["exit_status"].(string)
			if exitStatus != "" && exitStatus != "0" && exitStatus != "148" {
				return failedCommandStyle
			}
			return defaultStyle
		})

	m := &model{
		db:    db,
		input: input,
		table: t,

		showTimestamp:      true,
		showFailedCommands: true,
		showGlobalCommands: true,

		horizonTimestamp: time.Unix(int64(horizonTimestamp), 0),
		sessionID:        sessionID,
	}
	resModel, err := tea.NewProgram(m, tea.WithOutput(os.Stderr)).Run()
	if err != nil {
		panic(err)
	}

	m = resModel.(*model)
	if m.selection != "" {
		fmt.Println(m.selection)
	}
}
