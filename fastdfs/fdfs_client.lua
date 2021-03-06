local utils   = require('fastdfs.utils')
local fdfs_tracker   = require('fastdfs.tracker')
local fdfs_storage   = require('fastdfs.storage')
local fix_string   = utils.fix_string
local string = string
local table  = table
local bit    = bit
local ngx    = ngx
local tonumber = tonumber
local setmetatable = setmetatable
local error = error
local type = type
local pairs = pairs
local tostring = tostring

local VERSION = '0.1'
local FDFS_V4 = true
local default_chunk_size = 1024 * 32

local _M = {}
local mt = { __index = _M }

function _M.new(self)
    return setmetatable({}, mt)
end

function _M.set_trackers(self, trackers)
    --trackers = {{host=xxxx, port=xxxxx}}

    self.trackers = trackers or {}
end

function _M.set_tracker(self, host, port)
    local tracker = {host = host, port = port}
    self.tracker = tracker
end

function _M.set_timeout(self, timeout)
    if timeout then
        self.timeout = timeout
    end
end

function _M.set_tracker_keepalive(self, keepalive)
    self.tracker_keepalive = keepalive
end

function _M.set_storage_keepalive(self, keepalive)
    self.storage_keepalive = keepalive
end


--function _M.set_tracker_keepalive(self, timeout, size)
--    local keepalive = {timeout = timeout, size = size}
--    self.tracker_keepalive = keepalive
--end

--function _M.set_storage_keepalive(self, timeout, size)
--    local keepalive = {timeout = timeout, size = size}
--    self.storage_keepalive = keepalive
--end

function _M.get_tracker(self)
    local tk = fdfs_tracker:new(self.timeout, self.tracker_keepalive)
    tk:set_v4(FDFS_V4)
    local addr = self.trackers[math.random(#self.trackers)]
    local ok, err = tk:connect(addr)
    if ok then
        return tk
    end

    --if random one failed, try other
    for _, addr in pairs(self.trackers) do
       local ok, err = tk:connect(addr)
       if ok then
           return tk
       else
           ngx.log(ngx.ERR, "can't connect to tracker ", addr.host, ":", addr.port, ". auto try next one.." )
       end
    end
    return nil, "No Avaliable Tracker Server"
end


function _M.get_storage(self, store_info)
    local st = fdfs_storage:new(self.timeout, self.storage_keepalive)
    local ok, err = st:connect(store_info)
    if not ok then
        return nil, err
    end
    return st
end

function _M.list_groups(self)
    local tk,err = self:get_tracker()
    if not tk then
        return nil, err
    end
    return tk:list_groups()
end

function _M.list_group_servers(self, group_name)
    local tk,err = self:get_tracker()
    if not tk then
        return nil, err
    end
    return tk:list_servers(group_name)
end

function _M.do_upload(self, group, reader, file_size, ext_name, chunk_size)
    if not chunk_size then
        chunk_size = default_chunk_size
    end

    local reader = reader
    if not reader then
        return nil, "upload reader is nil"
    end

    if not file_size or file_size <= 0 then
        return nil, "invalid file size" .. file_size
    end

    local tk,err = self:get_tracker()
    if not tk then
        return nil, err
    end

    local storage = tk:query_storage_store(group)
    if not storage then
        return nil, "can't query storage"
    end

    local st_conn, err = self:get_storage(storage)
    if not st_conn then
        return nil, err
    end

    --send data
    return st_conn:upload_by_reader(reader, file_size, ext_name, chunk_size)
end


function _M.do_upload_appender(self, gourp, reader, filesize, ext_name, chunk_size)
    if not chunk_size then
        chunk_size = default_chunk_size
    end

    local reader = reader
    if not reader then
        return nil, "reader is nil"
    end

    -- get file size
    local file_size = filesize or 0

    local tk,err = self:get_tracker()
    if not tk then
        return nil, err
    end

    local storage = tk:query_storage_store(group)
    if not storage then
        return nil, "can't query storage"
    end

    local st_conn, err = self:get_storage(storage)
    if not st_conn then
        return nil, err
    end

    --send data
    return st_conn:upload_appender_by_reader(reader, file_size, ext_name, chunk_size)
end


function _M.do_delete(self, fileid, storage_ip)
    ngx.log(ngx.DEBUG, "delete fileid ", fileid, " storage: ", storage_ip)
    local storage = nil
    local st_conn, err = nil, nil
    if storage_ip and string.match(storage_ip,"%d+.%d+.%d+.%d+") then
        storage = {host=storage_ip}
        st_conn, err = self:get_storage(storage)
    end
    if not st_conn then
        ngx.log(ngx.ERR, "connect storage ", storage_ip, " failed, err: ", err)
        local tk,err = self:get_tracker()
        if not tk then
            return nil, err
        end
        storage = tk:query_storage_fetch1(fileid)
        if not storage then
            return nil, "can't query storage"
        end

        st_conn, err = self:get_storage(storage)
        if not st_conn then
            return nil, err
        end
    end

    return st_conn:delete_file1(fileid)
end


function _M.do_download(self, fileid, start, stop, storage_ip, failover)
    if failover == nil then
        failover = true
    end
    local storage = nil
    local st_conn, err = nil, nil
    if storage_ip and string.match(storage_ip,"%d+.%d+.%d+.%d+") then
        storage = {host=storage_ip}
        st_conn, err = self:get_storage(storage)
    end
    if not st_conn and failover then
        local tk,err = self:get_tracker()
        if not tk then
            return nil, nil, err
        end
        storage = tk:query_storage_fetch1(fileid)
        if not storage then
            return nil, nil, "can't query storage"
        end
        ngx.log(ngx.ERR, "failover storage:", storage.host)
        st_conn, err = self:get_storage(storage)
        if not st_conn then
            return nil, nil, err
        end
    elseif not st_conn then
        return nil, nil, err
    end


    local chunk_size = default_chunk_size or 1024 * 64
    return st_conn:download_file_to_reader(fileid, start,stop, chunk_size)
end

function _M.do_append(self, fileid, reader, file_size, chunk_size )
    if not chunk_size then
        chunk_size = default_chunk_size
    end

    local reader = reader
    if not reader then
        return nil, "reader is nil"
    end

    -- get file size
    if not file_size or file_size <= 0 then
        ngx.log(ngx.ERR, "fdfs: append file size nil")
        return nil
    end

    local tk, err = self:get_tracker()
    if not tk then
        return nil, err
    end

    local storage = tk:query_storage_update1(fileid)
    if not storage then
        return nil, "can't query storage"
    end

    local st_conn, err = self:get_storage(storage)
    if not st_conn then
        return nil, err
    end

    --send data
    return st_conn:append_by_reader(fileid, reader, file_size, chunk_size)
end


local function read_file_info_result(sock)
    local sock = sock
    if not sock then
        ngx.log(ngx.ERR, "read file info sock nil ")
        return nil, "not initialized"
    end
    local hdr, err = read_fdfs_header(sock)
    if not hdr then
        ngx.log(ngx.ERR, "read  header error")
        return nil, "read storage header error:" .. err
    end
    if hdr.status ~= 0 then
        ngx.log(ngx.ERR, "read  header status error: " .. hdr.status)
        return nil, "read storage status error:" .. hdr.status
    end
    if hdr.len > 0 then
        local data, err, partial = sock:receive(hdr.len)
        if not data then
            return nil, "read file body error:" .. err
        end
        ngx.log(ngx.ERR, "read data: " .. data, " len:", hdr.len)

        local offset = 1
        local filesize_str = string.sub(data, offset, offset+8-1)
        offset = offset + 8
        local filesize = buf2long(filesize_str)

        local timestamp_str = string.sub(data, offset, offset+8-1)
        offset = offset + 8
        local timestamp = buf2long(timestamp_str)

        local crc32_str = string.sub(data, offset, offset+8-1)
        offset = offset + 8
        local crc32 = buf2long(crc32_str)

        local source_ip_addr = strip_string(string.sub(data, offset))

        local fileinfo = {
            source_ip_addr = source_ip_addr,
            timestamp = timestamp,
            crc32 = crc32,
            filesize = filesize
        }
        return fileinfo
    else
        ngx.log(ngx.ERR, "read  header len: " .. hdr.len)
    end
    return nil
end

function _M.get_fileinfo_from_storage(self, fileid, storage_ip, failover)
    if failover == nil then
        failover = true
    end

    local storage = nil
    local st_conn, err = nil, nil
    if storage_ip and string.match(storage_ip,"%d+.%d+.%d+.%d+") then
        storage = {host=storage_ip}
        st_conn, err = self:get_storage(storage)
    end
    if not st_conn and failover then
        local tk,err = self:get_tracker()
        if not tk then
            return nil, nil, err
        end
        storage = tk:query_storage_update1(fileid)
        if not storage then
            return nil, nil, "can't query storage"
        end
        ngx.log(ngx.ERR, "failover storage:", storage.host)
        st_conn, err = self:get_storage(storage)
        if not st_conn then
            return nil, nil, err
        end
    elseif not st_conn then
        return nil, nil, err
    end
    --send data
    return st_conn:get_file_info1(fileid)
end

-- _M.query_upload_storage = query_upload_storage
-- _M.do_upload_storage    = do_upload_storage
-- _M.do_delete_storage    = do_delete_storage

local class_mt = {
    -- to prevent use of casual module global variables
    __newindex = function (table, key, val)
        error('attempt to write to undeclared variable "' .. key .. '"')
    end
}

setmetatable(_M, class_mt)
return _M
