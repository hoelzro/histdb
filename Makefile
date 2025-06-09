MODULES = match_timestamps.lua pretty.lua
TEST_DB = sample_history.db
TEST_SQL = sample_history.sql

histdb.lua: build.lua init.lua $(MODULES)
	lua5.4 build.lua --entrypoint init.lua --output histdb.lua $(MODULES)

$(TEST_DB): $(TEST_SQL)
	sqlite3 $@ < $(TEST_SQL)

test: histdb.lua $(TEST_DB)
	lua5.4 match_timestamps_test.lua
	HISTDB_PATH=$(PWD)/$(TEST_DB) lua5.4 invariants_test.lua

clean:
	rm -f histdb.lua $(TEST_DB)
