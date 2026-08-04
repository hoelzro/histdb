#!/usr/bin/env python3
"""Generate a ~750K row histdb database for benchmarking."""

import argparse
import random
import sqlite3
import uuid

HOSTNAMES = ['workstation', 'laptop', 'devbox']

DIRECTORIES = [
    '/home/rob',
    '/home/rob/projects',
    '/home/rob/projects/histdb-redux',
    '/home/rob/projects/webapp',
    '/home/rob/projects/infra',
    '/home/rob/projects/scripts',
    '/home/rob/documents',
    '/home/rob/.config',
    '/tmp',
    '/var/log',
]

# Weighted command templates — common commands appear more often.
COMMANDS = [
    ('git status', 15),
    ('git diff', 10),
    ('git add -A', 8),
    ('git commit -m "wip"', 5),
    ('git push', 5),
    ('git pull', 5),
    ('git log --oneline', 8),
    ('git checkout -b feature', 3),
    ('git stash', 3),
    ('vim {file}', 20),
    ('nvim {file}', 10),
    ('ls -la', 15),
    ('ls', 10),
    ('cd {dir}', 10),
    ('cat {file}', 8),
    ('grep -r pattern .', 5),
    ('make', 8),
    ('make test', 6),
    ('make clean', 3),
    ('python3 {file}', 5),
    ('pytest', 4),
    ('npm install', 3),
    ('npm run build', 3),
    ('npm test', 3),
    ('docker ps', 4),
    ('docker compose up -d', 3),
    ('ssh devbox', 2),
    ('curl -s http://localhost:8080/health', 3),
    ('echo $?', 5),
    ('man {cmd}', 2),
    ('which {cmd}', 2),
    ('ps aux', 3),
    ('top', 2),
    ('htop', 2),
    ('tail -f /var/log/syslog', 2),
    ('sudo systemctl restart nginx', 1),
    ('pip install -r requirements.txt', 2),
    ('cargo build', 2),
    ('cargo test', 2),
    ('lua5.4 test.lua', 2),
    ('jq . response.json', 3),
    ('sqlite3 db.sqlite', 2),
    ('tmux new -s work', 1),
    ('tmux attach', 2),
    ('export FOO=bar', 2),
    ('env | grep PATH', 2),
    ('chmod +x script.sh', 1),
    ('tar xzf archive.tar.gz', 1),
    ('rsync -avz src/ dest/', 1),
    ('find . -name "*.log" -delete', 1),
]

FILES = [
    'init.lua', 'main.py', 'app.js', 'index.html', 'Makefile',
    'README.md', 'config.yaml', 'test.py', 'server.py', 'utils.lua',
    'Dockerfile', 'docker-compose.yml', '.env', 'schema.sql',
    'requirements.txt', 'package.json', 'Cargo.toml', 'go.mod',
]

CMDS_FOR_WHICH = ['python3', 'node', 'cargo', 'go', 'lua5.4', 'sqlite3', 'jq', 'git']

# A deliberately rare command used to exercise slow MATCH + self-join cases.
RARE_COMMAND = 'RARE_BENCH_TOKEN fetch obscure benchmark data'


def build_command_pool():
    pool = []
    for template, weight in COMMANDS:
        for _ in range(weight):
            pool.append(template)
    return pool


def render_command(template):
    if '{file}' in template:
        return template.replace('{file}', random.choice(FILES))
    if '{dir}' in template:
        return template.replace('{dir}', random.choice(DIRECTORIES))
    if '{cmd}' in template:
        return template.replace('{cmd}', random.choice(CMDS_FOR_WHICH))
    return template


def generate(db_path, target_rows, seed, entry_trigram_index=True):
    rng = random.Random(seed)
    random.seed(seed)  # for random.choice in render_command

    pool = build_command_pool()

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute('PRAGMA journal_mode=WAL')
    cur.execute('''CREATE TABLE history (
        hostname TEXT,
        session_id TEXT,
        timestamp INTEGER,
        history_id INTEGER,
        cwd TEXT,
        entry TEXT,
        duration INTEGER,
        exit_status INTEGER
    )''')

    # Time range: 2 years ending roughly "now" (2026-01-01 to be deterministic).
    t_end = 1735689600    # 2025-01-01 00:00:00 UTC
    t_start = t_end - 2 * 365 * 86400

    rows_inserted = 0
    history_id = 1

    # Decide how many sessions contain the rare command (3-5 sessions, scattered).
    rare_session_count = rng.randint(3, 5)
    rare_sessions_placed = 0
    # Place rare-command sessions at roughly evenly-spaced intervals through generation.
    rare_session_targets = set()
    session_count_estimate = target_rows // 50  # rough avg commands per session
    for i in range(rare_session_count):
        rare_session_targets.add(
            int((i + 0.5) * session_count_estimate / rare_session_count)
        )

    session_number = 0
    batch = []
    BATCH_SIZE = 5000

    while rows_inserted < target_rows:
        hostname = rng.choice(HOSTNAMES)
        session_id = str(uuid.UUID(int=rng.getrandbits(128), version=4))
        session_start = rng.randint(t_start, t_end)

        # Session length: mostly short (5-30 commands), occasionally long (50-200).
        if rng.random() < 0.1:
            session_len = rng.randint(50, 200)
        else:
            session_len = rng.randint(5, 30)

        is_rare_session = session_number in rare_session_targets

        cwd = rng.choice(DIRECTORIES)
        t = session_start

        for cmd_idx in range(session_len):
            if rows_inserted >= target_rows:
                break

            # Occasionally change directory.
            if rng.random() < 0.15:
                cwd = rng.choice(DIRECTORIES)

            # Pick command.
            if is_rare_session and cmd_idx == rng.randint(0, session_len - 1):
                entry = RARE_COMMAND
                rare_sessions_placed += 1
                is_rare_session = False  # only once per session
            else:
                entry = render_command(rng.choice(pool))

            duration = rng.randint(0, 30) if rng.random() < 0.9 else rng.randint(30, 300)
            exit_status = 0 if rng.random() < 0.85 else rng.choice([1, 2, 126, 127, 130])

            batch.append((
                hostname, session_id, t, history_id,
                cwd, entry, duration, exit_status,
            ))

            t += duration + rng.randint(1, 60)
            history_id += 1
            rows_inserted += 1

        if len(batch) >= BATCH_SIZE:
            cur.executemany(
                'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                batch,
            )
            batch.clear()

        session_number += 1

    if batch:
        cur.executemany(
            'INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            batch,
        )

    cur.execute('CREATE INDEX history_timestamp_idx ON history(timestamp)')

    if entry_trigram_index:
        cur.executescript("""
            CREATE VIRTUAL TABLE history_entry_trigram_idx
            USING fts5(entry, content='history', content_rowid='rowid', tokenize='trigram');

            INSERT INTO history_entry_trigram_idx(history_entry_trigram_idx) VALUES('rebuild');

            CREATE TRIGGER history_entry_trigram_ai
            AFTER INSERT ON history BEGIN
              INSERT INTO history_entry_trigram_idx(rowid, entry)
              VALUES (new.rowid, new.entry);
            END;

            CREATE TRIGGER history_entry_trigram_ad
            AFTER DELETE ON history BEGIN
              INSERT INTO history_entry_trigram_idx(history_entry_trigram_idx, rowid, entry)
              VALUES('delete', old.rowid, old.entry);
            END;

            CREATE TRIGGER history_entry_trigram_au
            AFTER UPDATE OF entry ON history BEGIN
              INSERT INTO history_entry_trigram_idx(history_entry_trigram_idx, rowid, entry)
              VALUES('delete', old.rowid, old.entry);

              INSERT INTO history_entry_trigram_idx(rowid, entry)
              VALUES (new.rowid, new.entry);
            END;
        """)

    conn.commit()

    # Print stats.
    cur.execute('SELECT COUNT(*) FROM history')
    total = cur.fetchone()[0]
    cur.execute('SELECT COUNT(DISTINCT session_id) FROM history')
    sessions = cur.fetchone()[0]
    cur.execute('SELECT COUNT(*) FROM history WHERE entry LIKE ?', ('%RARE_BENCH_TOKEN%',))
    rare_rows = cur.fetchone()[0]

    print(f'Generated {total:,} rows across {sessions:,} sessions')
    print(f'RARE_BENCH_TOKEN entries: {rare_rows}')
    print(f'Entry trigram index: {"yes" if entry_trigram_index else "no"}')
    print(f'Database: {db_path}')

    conn.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Generate a benchmark histdb database.')
    parser.add_argument('-o', '--output', default='bench/bench.db', help='output database path')
    parser.add_argument('-n', '--rows', type=int, default=750_000, help='approximate row count')
    parser.add_argument('--seed', type=int, default=42, help='random seed for reproducibility')
    parser.add_argument(
        '--no-entry-trigram-index',
        action='store_true',
        help='skip the optional FTS5 trigram index for entry MATCH benchmarks',
    )
    args = parser.parse_args()

    generate(args.output, args.rows, args.seed, not args.no_entry_trigram_index)
