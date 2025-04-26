histdb-browser:
	make -C ../ histdb.lua
	cp ../histdb.lua .
	go build -mod=mod -tags libsqlite3 -o $@  .

clean:
	rm -f histdb-browser
