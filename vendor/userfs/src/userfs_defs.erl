-module(userfs_defs).

-include_lib("efuse/include/efuse_defs.hrl").

-export([
	status_data/0,
	request_readdir/0,
	request_getattr/0,
	request_readlink/0,
	request_read/0,
	request_open/0,
	open_direct_io/0,
	attr_dir/0,
	attr_file/0,
	attr_symlink/0,
	error_noent/0,
	magiccookie/0
]).

status_data()      -> ?EFUSE_STATUS_DATA .
request_readdir()  -> ?EFUSE_REQUEST_READDIR .
request_getattr()  -> ?EFUSE_REQUEST_GETATTR .
request_readlink() -> ?EFUSE_REQUEST_READLINK .
request_read()     -> ?EFUSE_REQUEST_READ .
request_open()     -> ?EFUSE_REQUEST_OPEN .
open_direct_io()   -> ?EFUSE_OPEN_DIRECT_IO .
attr_dir()         -> ?EFUSE_ATTR_DIR .
attr_file()        -> ?EFUSE_ATTR_FILE .
attr_symlink()     -> ?EFUSE_ATTR_SYMLINK .
error_noent()      -> ?EFUSE_ERROR_NOENT .
magiccookie()      -> ?EFUSE_MAGICCOOKIE .
