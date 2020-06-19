#!/usr/bin/env lua

--[[
 (с) 2020 gSpot (https://github.com/gSpotx2f/ruantiblock_openwrt)

 lua == 5.1
--]]

-------------------------- Class constructor -------------------------

local function Class(super, t)
    local class = t or {}
    local function instance_constructor(cls, t)
        local instance = t or {}
        setmetatable(instance, cls)
        instance.__class = cls
        return instance
    end
    if not super then
        local mt = {__call = instance_constructor}
        mt.__index = mt
        setmetatable(class, mt)
    elseif type(super) == "table" and super.__index and super.__call then
        setmetatable(class, super)
        class.__super = super
    else
        error("Argument error! Incorrect object of a 'super'")
    end
    class.__index = class
    class.__call = instance_constructor
    return class
end

------------------------------ Settings ------------------------------

local Config = Class(nil, {
    environ_table = {
        ["EXEC_DIR"] = true,
        ["BLLIST_SOURCE"] = true,
        ["BLLIST_MODE"] = true,
        ["ALT_NSLOOKUP"] = true,
        ["ALT_DNS_ADDR"] = true,
        ["USE_IDN"] = true,
        ["OPT_EXCLUDE_SLD"] = true,
        ["OPT_EXCLUDE_MASKS"] = true,
        ["FQDN_FILTER"] = true,
        ["FQDN_FILTER_FILE"] = true,
        ["IP_FILTER"] = true,
        ["IP_FILTER_FILE"] = true,
        ["SD_LIMIT"] = true,
        ["IP_LIMIT"] = true,
        ["OPT_EXCLUDE_NETS"] = true,
        ["BLLIST_MIN_ENTRS"] = true,
        ["STRIP_WWW"] = true,
        ["DATA_DIR"] = true,
        ["IPSET_DNSMASQ"] = true,
        ["IPSET_IP_TMP"] = true,
        ["IPSET_CIDR_TMP"] = true,
        ["DNSMASQ_DATA_FILE"] = true,
        ["IP_DATA_FILE"] = true,
        ["UPDATE_STATUS_FILE"] = true,
        ["RBL_ALL_URL"] = true,
        ["RBL_IP_URL"] = true,
        ["ZI_ALL_URL"] = true,
        ["AF_IP_URL"] = true,
        ["AF_FQDN_URL"] = true,
        ["AZ_ENCODING"] = true,
        ["RBL_ENCODING"] = true,
        ["ZI_ENCODING"] = true,
        ["AF_ENCODING"] = true,
        ["SUMMARIZE_IP"] = true,
        ["SUMMARIZE_CIDR"] = true,
    },
    FQDN_FILTER_PATTERNS = {},
    IP_FILTER_PATTERNS = {},
    -- iconv type: standalone iconv or lua-iconv (standalone, lua)
    ICONV_TYPE = "standalone",
    -- standalone iconv
    ICONV_CMD = "iconv",
    WGET_CMD = "wget --no-check-certificate -q -O -",
    encoding = "UTF-8",
    site_encoding = "",
    http_send_headers = {
        --["User-Agent"] = "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:68.0) Gecko/20100101 Firefox/68.0",
    },
})
Config.wget_user_agent = (Config.http_send_headers["User-Agent"]) and ' -U "' .. Config.http_send_headers["User-Agent"] .. '"' or ''

-- Load external config

function Config:load_config(t)
    local config_arrays = {
        ["OPT_EXCLUDE_SLD"] = true,
        ["OPT_EXCLUDE_NETS"] = true,
    }
    for k, v in pairs(t) do
        if config_arrays[k] then
            local value_table = {}
            for v in v:gmatch('[^" ]+') do
                value_table[v] = true
            end
            self[k] = value_table
        else
            self[k] = v:match("^[0-9.]+$") and tonumber(v) or v:gsub('"', '')
        end
    end
end

function Config:load_environ_config()
    local cfg_table = {}
    for var in pairs(self.environ_table) do
        val = os.getenv(var)
        if val then
            cfg_table[var] = val
        end
    end
    self:load_config(cfg_table)
end

Config:load_environ_config()

local function remap_bool(val)
    return (val ~= 0 and val ~= false and val ~= nil) and true or false
end

Config.ALT_NSLOOKUP = remap_bool(Config.ALT_NSLOOKUP)
Config.USE_IDN = remap_bool(Config.USE_IDN)
Config.STRIP_WWW = remap_bool(Config.STRIP_WWW)
Config.FQDN_FILTER = remap_bool(Config.FQDN_FILTER)
Config.IP_FILTER = remap_bool(Config.IP_FILTER)
Config.SUMMARIZE_IP = remap_bool(Config.SUMMARIZE_IP)
Config.SUMMARIZE_CIDR = remap_bool(Config.SUMMARIZE_CIDR)

-- Load filters

function Config:load_filter_files()
    function load_file(file, t)
        local file_handler = io.open(file, "r")
        if file_handler then
            for line in file_handler:lines() do
                if #line > 0 and line:match("^[^#]") then
                    t[line] = true
                end
            end
            file_handler:close()
        end
    end
    if self.FQDN_FILTER then
        load_file(self.FQDN_FILTER_FILE, self.FQDN_FILTER_PATTERNS)
    end
    if self.IP_FILTER then
        load_file(self.IP_FILTER_FILE, self.IP_FILTER_PATTERNS)
    end
end

Config:load_filter_files()

-- Import packages

local function prequire(package)
    local ret_val, pkg = pcall(require, package)
    return ret_val and pkg
end

local http = prequire("socket.http")
local https = prequire("ssl.https")
local ltn12 = prequire("ltn12")
if not ltn12 then
    error("You need to install luasocket or ltn12...")
end

local idn = prequire("idn")
if Config.USE_IDN and not idn then
    error("You need to install idn.lua (github.com/haste/lua-idn) or 'USE_IDN' must be set to '0'")
end
local iconv = prequire("iconv")

local si, it
if prequire("bit") then
    it = prequire("iptool")
    if it then
        si = prequire("ruab_sum_ip")
    end
end
if not si then
    Config.SUMMARIZE_CIDR = false
    Config.SUMMARIZE_IP = false
end

-- Check iconv

if Config.ICONV_TYPE == "standalone" then
    local handler = io.popen("which " .. Config.ICONV_CMD)
    local ret_val = handler:read("*l")
    handler:close()
    if not ret_val then
        Config.ICONV_CMD = nil
    end
elseif Config.ICONV_TYPE == "lua" then
else
    error("Config.ICONV_TYPE should be either 'lua' or 'standalone'")
end

------------------------------ Classes -------------------------------

local BlackListParser = Class(Config, {
    ip_pattern = "%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?",
    cidr_pattern = "%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?/%d%d?",
    fqdn_pattern = "[a-z0-9_%.%-]-[a-z0-9_%-]+%.[a-z0-9%.%-]",
    url = "http://127.0.0.1",
    records_separator = "\n",
    ips_separator = " | ",
})

function BlackListParser:new(t)
    -- extended instance constructor
    local instance = self(t)
    instance.url = instance["url"] or self.url
    instance.records_separator = instance["records_separator"] or self.records_separator
    instance.ips_separator = instance["ips_separator"] or self.ips_separator
    instance.site_encoding = instance["site_encoding"] or self.site_encoding
    instance.ip_records_count = 0
    instance.ip_count = 0
    instance.ip_subnet_table = {}
    instance.cidr_count = 0
    instance.fqdn_table = {}
    instance.fqdn_count = 0
    instance.sld_table = {}
    instance.fqdn_records_count = 0
    instance.ip_table = {}
    instance.cidr_table = {}
    instance.iconv_handler = iconv and iconv.open(instance.encoding, instance.site_encoding) or nil
    return instance
end

function BlackListParser:convert_encoding(input)
    local output
    if self.ICONV_TYPE == "lua" and self.iconv_handler then
        output = self.iconv_handler:iconv(input)
    elseif self.ICONV_TYPE == "standalone" and self.ICONV_CMD then
        local iconv_handler = assert(io.popen('printf \'' .. input .. '\' | ' .. self.ICONV_CMD .. ' -f "' .. self.site_encoding .. '" -t "' .. self.encoding .. '"', 'r'))
        output = iconv_handler:read("*a")
        iconv_handler:close()
    end
    return (output)
end

function BlackListParser:convert_to_punycode(input)
    if self.site_encoding and self.site_encoding ~= "" then
        input = self:convert_encoding(input)
    end
    return input and (idn.encode(input))
end

function BlackListParser:check_filter(str, filter_patterns)
    if filter_patterns and str then
        for pattern in pairs(filter_patterns) do
            if str:match(pattern) then
                return true
            end
        end
    end
    return false
end

function BlackListParser:get_subnet(ip)
    return ip:match("^(%d+%.%d+%.%d+%.)%d+$")
end

function BlackListParser:fill_ip_tables(val)
    if val and val ~= "" then
        for ip_entry in val:gmatch(self.ip_pattern .. "/?%d?%d?") do
            if not self.IP_FILTER or (self.IP_FILTER and not self:check_filter(ip_entry, self.IP_FILTER_PATTERNS)) then
                if ip_entry:match("^" .. self.ip_pattern .. "$") and not self.ip_table[ip_entry] then
                    local subnet = self:get_subnet(ip_entry)
                    if subnet and (self.OPT_EXCLUDE_NETS[subnet] or ((not self.IP_LIMIT or self.IP_LIMIT == 0) or (not self.ip_subnet_table[subnet] or self.ip_subnet_table[subnet] < self.IP_LIMIT))) then
                        self.ip_table[ip_entry] = subnet
                        self.ip_subnet_table[subnet] = (self.ip_subnet_table[subnet] or 0) + 1
                        self.ip_count = self.ip_count + 1
                    end
                elseif ip_entry:match("^" .. self.cidr_pattern .. "$") and not self.cidr_table[ip_entry] then
                    self.cidr_table[ip_entry] = true
                    self.cidr_count = self.cidr_count + 1
                end
            end
        end
    end
end

function BlackListParser:get_sld(fqdn)
    return fqdn:match("^[a-z0-9_%.%-]-([a-z0-9_%-]+%.[a-z0-9%-]+)$")
end

function BlackListParser:fill_domain_tables(val)
    val = val:gsub("%*%.", ""):gsub("%.$", ""):lower()
    if self.STRIP_WWW then
        val = val:gsub("^www[0-9]?%.", "")
    end
    if not self.FQDN_FILTER or (self.FQDN_FILTER and not self:check_filter(val, self.FQDN_FILTER_PATTERNS)) then
        if val:match("^" .. self.fqdn_pattern .. "+$") then
        elseif self.USE_IDN and val:match("^[^\\/&%?]-[^\\/&%?%.]+%.[^\\/&%?%.]+%.?$") then
            val = self:convert_to_punycode(val)
            if not val then
                return false
            end
        else
            return false
        end
        local sld = self:get_sld(val)
        if sld and (self.OPT_EXCLUDE_SLD[sld] or ((not self.SD_LIMIT or self.SD_LIMIT == 0) or (not self.sld_table[sld] or self.sld_table[sld] < self.SD_LIMIT))) then
            self.fqdn_table[val] = sld
            self.sld_table[sld] = (self.sld_table[sld] or 0) + 1
            self.fqdn_count = self.fqdn_count + 1
        end
    end
    return true
end

function BlackListParser:sink()
    -- Must be reload in the subclass
    error("Method BlackListParser:sink() must be reload in the subclass!")
end

function BlackListParser:optimize_ip_table()
    local optimized_table = {}
    for ipaddr, subnet in pairs(self.ip_table) do
        if self.ip_subnet_table[subnet] then
            if (self.IP_LIMIT and self.IP_LIMIT > 0 and not self.OPT_EXCLUDE_NETS[subnet]) and self.ip_subnet_table[subnet] >= self.IP_LIMIT then
                self.cidr_table[string.format("%s0/24", subnet)] = true
                self.ip_subnet_table[subnet] = nil
                self.cidr_count = self.cidr_count + 1
            else
                optimized_table[ipaddr] = true
                self.ip_records_count = self.ip_records_count + 1
            end
        end
    end
    self.ip_table = optimized_table
end


function BlackListParser:optimize_fqdn_table()
    local optimized_table = {}
    if self.OPT_EXCLUDE_MASKS and #self.OPT_EXCLUDE_MASKS > 0 then
        for sld in pairs(self.sld_table) do
            for _, pattern in ipairs(self.OPT_EXCLUDE_MASKS) do
                if sld:find(pattern) then
                    self.sld_table[sld] = 0
                    break
                end
            end
        end
    end
    for fqdn, sld in pairs(self.fqdn_table) do
        local key_value = fqdn
        if (not self.fqdn_table[sld] or fqdn == sld) and self.sld_table[sld] then
            if (self.SD_LIMIT and self.SD_LIMIT > 0 and not self.OPT_EXCLUDE_SLD[sld]) and self.sld_table[sld] >= self.SD_LIMIT then
                key_value = sld
                self.sld_table[sld] = nil
            end
            optimized_table[key_value] = true
            self.fqdn_records_count = self.fqdn_records_count + 1
        end
    end
    self.fqdn_table = optimized_table
end

function BlackListParser:group_ip_ranges()
    for i in si.summarize_ip_ranges(self.ip_table, true) do
        self.cidr_table[string.format("%s/%s", it.int_to_ip(i[1]), i[2])] = true
    end
end

function BlackListParser:group_cidr_ranges()
    for i in si.summarize_nets(self.cidr_table, true) do
        self.cidr_table[string.format("%s/%s", it.int_to_ip(i[1]), i[2])] = true
    end
end

function BlackListParser:write_ipset_config()
    local file_handler = assert(io.open(self.IP_DATA_FILE, "w"), "Could not open ipset config")
    local i = 0
    for ipaddr in pairs(self.ip_table) do
        file_handler:write(string.format("add %s %s\n", self.IPSET_IP_TMP, ipaddr))
        i = i + 1
    end
    self.ip_records_count = i
    local c = 0
    for cidr in pairs(self.cidr_table) do
        file_handler:write(string.format("add %s %s\n", self.IPSET_CIDR_TMP, cidr))
        c = c + 1
    end
    self.cidr_count = c
    file_handler:close()
end

function BlackListParser:write_dnsmasq_config()
    local file_handler = assert(io.open(self.DNSMASQ_DATA_FILE, "w"), "Could not open dnsmasq config")
    for fqdn in pairs(self.fqdn_table) do
        if self.ALT_NSLOOKUP then
            file_handler:write(string.format("server=/%s/%s\n", fqdn, self.ALT_DNS_ADDR))
        end
        file_handler:write(string.format("ipset=/%s/%s\n", fqdn, self.IPSET_DNSMASQ))
    end
    file_handler:close()
end

function BlackListParser:write_update_status()
    local file_handler = assert(io.open(self.UPDATE_STATUS_FILE, "w"), "Could not open 'update_status' file")
    file_handler:write(string.format("%d %d %d", self.ip_records_count, self.cidr_count, self.fqdn_records_count))
    file_handler:close()
end

function BlackListParser:chunk_buffer()
    local buff = ""
    local ret_value = ""
    local last_chunk
    return function(chunk)
        if last_chunk then
            return nil
        end
        if chunk then
            buff = buff .. chunk
            local last_rs_position = select(2, buff:find("^.*" .. self.records_separator))
            if last_rs_position then
                ret_value = buff:sub(1, last_rs_position)
                buff = buff:sub((last_rs_position + 1), -1)
            else
                ret_value = ""
            end
        else
            ret_value = buff
            last_chunk = true
        end
        return (ret_value)
    end
end

function BlackListParser:get_http_data(url)
    local ret_val, ret_code, ret_headers
    local http_module = url:match("^https") and https or http
    if http_module then
        local http_sink = ltn12.sink.chain(self:chunk_buffer(), self:sink())
        ret_val, ret_code, ret_headers = http_module.request{url = url, sink = http_sink, headers = self.http_send_headers}
        if not ret_val or ret_code ~= 200 then
            ret_val = nil
            print(string.format("Connection error! (%s) URL: %s", ret_code, url))
        end
    end
    if not ret_val then
        local wget_sink = ltn12.sink.chain(self:chunk_buffer(), self:sink())
        ret_val = ltn12.pump.all(ltn12.source.file(io.popen(self.WGET_CMD .. self.wget_user_agent .. ' "' .. url .. '"', 'r')), wget_sink)
    end
    return (ret_val == 1) and true or false
end

function BlackListParser:run()
    local return_code = 0
    if self:get_http_data(self.url) then
        if (self.fqdn_count + self.ip_count + self.cidr_count) > self.BLLIST_MIN_ENTRS then
            self:optimize_fqdn_table()
            self:optimize_ip_table()
            if self.SUMMARIZE_IP then
                self:group_ip_ranges()
            end
            if self.SUMMARIZE_CIDR then
                self:group_cidr_ranges()
            end
            self:write_ipset_config()
            self:write_dnsmasq_config()
            return_code = 0
        else
            return_code = 2
        end
    else
        return_code = 1
    end
    self:write_update_status()
    return return_code
end

-- Subclasses

local function ip_sink(self)
    return function(chunk)
        if chunk and chunk ~= "" then
            for ip_string in chunk:gmatch(self.ip_string_pattern) do
                self:fill_ip_tables(ip_string)
            end
        end
        return true
    end
end

local function fqdn_sink_func(self, ip_str, fqdn_str)
    if #fqdn_str > 0 and not fqdn_str:match("^" .. self.ip_pattern .. "$") then
        if self:fill_domain_tables(fqdn_str) then
            return true
        end
    end
    self:fill_ip_tables(ip_str)
end

    -- rublacklist.net

local Rbl = Class(BlackListParser, {
    url = Config.RBL_ALL_URL,
    ips_separator = ", ",
    ip_string_pattern = "([a-f0-9/.:]+),?\n?",
})

function Rbl:sink()
    return function(chunk)
        if chunk and chunk ~= "" then
            for ip_str, fqdn_str in chunk:gmatch("%[([a-f0-9/.:', ]+)%],([^,]-),.-" .. self.records_separator) do
                fqdn_sink_func(self, ip_str, fqdn_str)
            end
        end
        return true
    end
end

local RblIp = Class(Rbl, {
    url = Config.RBL_IP_URL,
    sink = ip_sink,
})

    -- zapret-info

local Zi = Class(BlackListParser, {
    url = Config.ZI_ALL_URL,
    ip_string_pattern = "([a-f0-9%.:/ |]+);.-\n",
    site_encoding = Config.ZI_ENCODING,
})

function Zi:sink()
    return function(chunk)
        if chunk and chunk ~= "" then
            for ip_str, fqdn_str in chunk:gmatch("([^;]-);([^;]-);.-" .. self.records_separator) do
                fqdn_sink_func(self, ip_str, fqdn_str)
            end
        end
        return true
    end
end

local ZiIp = Class(Zi, {
    sink = ip_sink,
})

    -- antifilter

local Af = Class(BlackListParser, {
    url = Config.AF_FQDN_URL,
    ip_string_pattern = "(.-)\n",
})

function Af:sink()
    local entry_pattern = "((.-))" .. self.records_separator
    return function(chunk)
        if chunk and chunk ~= "" then
            for fqdn_str, ip_str in chunk:gmatch(entry_pattern) do
                fqdn_sink_func(self, ip_str, fqdn_str)
            end
        end
        return true
    end
end

local AfIp = Class(Af, {
    url = Config.AF_IP_URL,
    sink = ip_sink,
    BLLIST_MIN_ENTRS = 100,
})

----------------------------- Main section ------------------------------

local ctx_table = {
    ["ip"] = {["rublacklist"] = RblIp, ["zapret-info"] = ZiIp, ["antifilter"] = AfIp},
    ["fqdn"] = {["rublacklist"] = Rbl, ["zapret-info"] = Zi, ["antifilter"] = Af},
}

local return_code = 1
local ctx = ctx_table[Config.BLLIST_MODE] and ctx_table[Config.BLLIST_MODE][Config.BLLIST_SOURCE]
if ctx then
    return_code = ctx:new():run()
else
    error("Wrong configuration! (Config.BLLIST_MODE or Config.BLLIST_SOURCE)")
end

os.exit(return_code)
