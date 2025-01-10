local ngx = ngx
local http = require "resty.http"
local _M = {}

-- Default maximum allowed body size
local MAX_BODY_SIZE = 64 * 1024  -- in Bytes
local REQUEST_TIMEOUT = 2000 -- in ms

local function copy_headers(from_headers, to_headers, prefix)
    for k, v in pairs(from_headers) do
        if k:sub(1, #prefix) == prefix then
            ngx.log(ngx.DEBUG, "Copying header: ", k, " = ", v)
            to_headers[k] = v
        end
    end
end

local function get_raw_header_keys()
    local raw_headers = ngx.req.raw_header(true)
    local header_keys = {}

    for line in raw_headers:gmatch("[^\r\n]+") do
        local header_key = line:match("^([^:]+):")
        if header_key then
            table.insert(header_keys, header_key)
        end
    end

    return table.concat(header_keys, ":")
end

local function forward_custom_headers()
    local headers = ngx.req.get_headers()
    headers["X-Server-Port"] = ngx.var.server_port
    headers["X-Forwarded-For"] = headers["X-Forwarded-For"] and headers["X-Forwarded-For"] .. ", " .. ngx.var.remote_addr or ngx.var.remote_addr
    headers["X-Forward-Port"] = ngx.var.remote_port
    headers["X-Forward-Proto"] = ngx.var.scheme
    headers["X-Request-ID"] = ngx.var.request_id
    headers["X-Original-Protocol"] = ngx.req.http_version()
    if ngx.req.http_version() < 2 then
        headers["X-Header-Names"] = get_raw_header_keys()
    end
    return headers
end

-- Function to read the body (from memory or file) if allowed by method and content length
local function read_request_body(method, content_length)
    
    if content_length and content_length <= MAX_BODY_SIZE then
        ngx.req.read_body()

        local body_data = ngx.req.get_body_data()
        if body_data then
            ngx.log(ngx.DEBUG, "Body found in memory")
            return body_data
        end

        local body_file = ngx.req.get_body_file()
        if body_file then
            ngx.log(ngx.DEBUG, "Body found in file: " .. body_file)
            local file, err = io.open(body_file, "rb")
            if not file then
                ngx.log(ngx.ERR, "Failed to open body file: " .. err)
                return nil
            end
            local file_content = file:read("*all")
            file:close()
            return file_content
        end
    else
        if content_length then
            ngx.log(ngx.ERR,
                string.format("Request body not inspected. Content length (%s) exceeds the max allowed size (%d)",
                    content_length, MAX_BODY_SIZE, ngx.var.remote_addr, ngx.var.request_uri))
        end
    end
    return nil
end

function _M.check_aaph_access()
    local start_time = ngx.now()
    ngx.log(ngx.DEBUG, "aaph check request: ")

    local httpc = http.new()
    httpc:set_timeouts(REQUEST_TIMEOUT, REQUEST_TIMEOUT, REQUEST_TIMEOUT)  -- (connect, send, read)ms

    local socket_path = "unix:/var/aaph/aaph.sock"
    local ok, err = httpc:connect({
        host = socket_path,
    })
    if not ok then
        ngx.log(ngx.ERR, "Failed to connect to socket: ", err)
        return -- Fail open: do not block the request, allow it to proceed
    end

    local method = ngx.req.get_method()
    local uri = ngx.var.request_uri
    local headers = forward_custom_headers()
    local content_length = tonumber(headers["content-length"])
    local body_data = read_request_body(method,content_length)
    if not body_data then
        ngx.log(ngx.DEBUG, "No body data found, setting content length to 0")
        headers["content-length"] = 0
    end

    local http_version = 1.1
    if ngx.req.http_version() == 1.0 then
        http_version = 1.0
    end

    local res, send_err = httpc:request({
        path = uri,
        method = method,
        headers = headers,
        body = body_data,
        version = http_version,
    })

    if not res then
        ngx.log(ngx.ERR, "Failed to request: ", send_err)
        -- return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        return  -- Fail open: do not block the request, allow it to proceed
    end
    ngx.log(ngx.INFO, "aaph response status, length, body: ", res.status)

    -- Copy response headers with prefix "Akamai-X"
    copy_headers(res.headers, ngx.header, "Akamai-X")
    if res.status == 403 then
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    local ok, err = httpc:set_keepalive()
    if not ok then
        ngx.log(ngx.ERR, "failed to set keepalive: ", err)
        return
    end

    ngx.update_time()
    ngx.log(ngx.INFO, "Request ID: ", ngx.var.request_id," | time taken by aaph rewrite: ", ngx.now() - start_time)
end

return _M.check_aaph_access()
