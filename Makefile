MODULES = match_timestamps.lua pretty.lua

histdb.lua: build.lua init.lua $(MODULES)
	lua build.lua --entrypoint init.lua --output histdb.lua $(MODULES)

clean:
	rm -f histdb.lua
