package = "histdb"
version = "scm-1"

source = {
   url = "git://github.com/hoelzro/histdb",
}

description = {
   summary = "Shell history stored in SQLite, exposed as a virtual table",
   license = "MIT",
}

dependencies = {
   "lua >= 5.4",
   "lsqlite3",
   "lpeg",
   "cjson",
   "dkjson",
   "luaposix",
}

build = {
   type = "none",
}
