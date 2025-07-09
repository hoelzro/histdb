MODULES = match_timestamps.lua pretty.lua
TEST_SQL = sample_history.sql

histdb.lua: build.lua init.lua $(MODULES)
	lua5.4 build.lua --entrypoint init.lua --output histdb.lua $(MODULES)

test: histdb.lua $(TEST_SQL)
	lua5.4 match_timestamps_test.lua
	temp_db=$$(mktemp); \
	echo $$temp_db ; \
	sqlite3 $$temp_db < $(TEST_SQL) && \
	HISTDB_PATH=$$temp_db lua5.4 invariants_test.lua; \
	exit_code=$$?; \
	rm -f $$temp_db; \
	exit $$exit_code

clean:
	rm -f histdb.lua
