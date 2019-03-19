-- Version 1.4.0

local CONFIG_FILE = 'credentials.json'
local config = {}
local virtual_pio = {ctrl=0x1f}

local function readConfig(file_name)
    local file = io.open(file_name)
    local text = file:read("*a")
    file:close()
    local config = cjson.decode(text)
    return config
end

local function pio_create(ctrl)
    if type(ctrl)~="number" then 
        return -1
    else 
        virtual_pio.ctrl = bit32.band(0x1f, bit32.bnot(ctrl))
        return 0
    end
end

local function pio_destroy()
    virtual_pio.ctrl = 0x1f
    virtual_pio.input = nil
    virtual_pio.output = nil
    return 0
end

local function pio_writeOutput(data)
    if virtual_pio.ctrl==nil then
        return -1, nil, nil
    end
    local s, input
    s, input = fa.pio(virtual_pio.ctrl, data)
    if s==0 then
        return 0, nil, nil
    end
    virtual_pio.output = bit32.band(virtual_pio.ctrl, data)
    virtual_pio.input = bit32.band(bit32.bnot(virtual_pio.ctrl), input)
    return 1, virtual_pio.ctrl, virtual_pio.input
end

local function pio_readInput()
    if virtual_pio.ctrl==nil then
        return -1, nil, nil
    end
    local s, input
    s, input = fa.pio(virtual_pio.ctrl, virtual_pio.output)
    if s==0 then
        return 0, nil, nil
    end
    virtual_pio.input = bit32.band(bit32.bnot(virtual_pio.ctrl), input)
    return 1, virtual_pio.ctrl, virtual_pio.input
end

local function addPio(ctrl, data, s)
    local body = cjson.encode({time='', pio={ctrl=ctrl, data=data}, s=s})
    b, c, h = fa.request {
        url=config.api_base .. '/v1/flashairs/' .. config.id .. '/measurements/pio',
        method='POST',
        headers={
            ['Authorization']='Basic ' .. config.credential,
            ['Content-Length']=tostring(string.len(body)),
            ['Content-Type']='application/json',
        },
        body=body,
    }
    print(c)
    print(b)
end

local function uploadPioInput()
    local s, ctrl, input
    s, ctrl, input = pio_readInput()
    if s==1 then
        return addPio(ctrl, input, s)
    end
end

local function getJobs()
    b, c, h = fa.request {
        url=config.api_base .. '/v1/flashairs/self/jobs',
        method='GET',
        headers={Authorization='Basic ' .. config.credential},
    }
    if c == 200 then
        return cjson.decode(b).jobs
    end
    print(c)
    return {}
end

local function getJob(job)
    b, c, h = fa.request {
        url=config.api_base .. '/v1/flashairs/self/jobs/' .. job.id,
        method='GET',
        headers={Authorization='Basic ' .. config.credential},
    }
    if c == 200 then
        local detail = cjson.decode(b)
        detail.etag = string.match(h, "Etag:%s*([a-zA-Z0-9]*)")
        return detail
    end
    print(c)
    return nil
end

local function updateJob(job, response, finalize)
    local body = cjson.encode({response=response, status='executed'})
    b, c, h = fa.request {
        url=config.api_base .. '/v1/flashairs/self/jobs/' .. job.id,
        method='PATCH',
        headers={
            ['Authorization']='Basic ' .. config.credential,
            ['Content-Length']=tostring(string.len(body)),
            ['Content-Type']='application/json',
            ['If-Match']=job.etag,
        },
        body=body,
    }
    print(b)
    print(c)
end

local function execJob(job)
    if job.request.type == "pio" then
        s, ctrl, output = pio_writeOutput(job.request.data)
        updateJob(job, {s=s, ctrl=ctrl, data=output}, true)
    elseif job.request.type == "script" then
        local script = loadfile(job.request.path)
        if script == nil then
            updateJob(job, {s=0, message="loadfile failed."}, true)
            return
        end
        arguments = job.request.arguments
        local ok, result = pcall(script)
        if ok then
            updateJob(job, {s=1, message="successfully executed.", result=result}, true)
            return
        end
        updateJob(job, {s=0, message=result}, true)
    end
end

local function runJob()
    local jobs = getJobs()
    for i, job in ipairs(jobs) do
        if job.status ~= "executed" then
            local detail = getJob(job)
            if detail ~= nil then
                execJob(detail)
            end
        end
    end
    uploadPioInput()
end

local function addMeasurement(values)
    local body = cjson.encode({values=values})
    b, c, h = fa.request {
        url=config.api_base .. '/v1/flashairs/' .. config.id .. '/measurements/simple',
        method='POST',
        headers={
            ['Authorization']='Basic ' .. config.credential,
            ['Content-Length']=tostring(string.len(body)),
            ['Content-Type']='application/json',
        },
        body=body,
    }
    print(c)
    print(b)
end

local function log(obj)
    local body = cjson.encode({log=obj})
    b, c, h = fa.request{
        url=config.api_base .. "/v1/flashairs/self/logs",
        method = "POST",
        headers = {
            ['Authorization']='Basic ' .. config.credential,
            ['Content-Length']=tostring(string.len(body)),
            ['Content-Type']='application/json',
        },
        body=body,
    }
end

local function uploadImage(file_path)
    local filesize = lfs.attributes(file_path,"size")
    if filesize ~= nil then
        print("Uploading "..file_path.." size: "..filesize)
    else
        print("Failed to find "..file_path.."... something wen't wrong!")
        return
    end
    boundary = "--61141483716826"
    contenttype = "multipart/form-data; boundary=" .. boundary
    local mes = "--".. boundary .. "\r\n"
      .."Content-Disposition: form-data; name=\"file\"; filename=\""..file_path.."\"\r\n"
      .."Content-Type: text/plain\r\n"
      .."\r\n"
      .."<!--WLANSDFILE-->\r\n"
      .."--" .. boundary .. "--\r\n"
    local blen = filesize + string.len(mes) - 17
    b,c,h = fa.request{
        url=config.api_base .. "/v1/flashairs/self/images",
        method="POST",
        headers={
            ['Authorization']='Basic ' .. config.credential,
            ["Content-Length"]=tostring(blen),
            ["Content-Type"]=contenttype,
        },
        file=file_path,
        body=mes,
        bufsize=1460*10,
    }
    print(c)
    print(b)
    return b
end

local function uploadFile(file_path)
    local filesize = lfs.attributes(file_path,"size")
    if filesize ~= nil then
        print("Uploading "..file_path.." size: "..filesize)
    else
        print("Failed to find "..file_path.."... something wen't wrong!")
        return
    end
    boundary = "--61141483716826"
    contenttype = "multipart/form-data; boundary=" .. boundary
    local mes = "--".. boundary .. "\r\n"
      .."Content-Disposition: form-data; name=\"file\"; filename=\""..fa.strconvert("sjis2utf8", file_path).."\"\r\n"
      .."Content-Type: text/plain\r\n"
      .."\r\n"
      .."<!--WLANSDFILE-->\r\n"
      .."--" .. boundary .. "--\r\n"
    local blen = filesize + string.len(mes) - 17
    b,c,h = fa.request{
        url=config.api_base .. "/v1/flashairs/self/files",
        method="POST",
        headers={
            ['Authorization']='Basic ' .. config.credential,
            ["Content-Length"]=tostring(blen),
            ["Content-Type"]=contenttype,
        },
        file=file_path,
        body=mes,
        bufsize=1460*10,
    }
    print(c)
    print(b)
    return b
end

local function uploadCSV(file_path, timestamp_type, timestamp_unit)
    local filesize = lfs.attributes(file_path,"size")
    if filesize ~= nil then
        print("Uploading "..file_path.." size: "..filesize)
    else
        print("Failed to find "..file_path.."... something wen't wrong!")
        return
    end
    boundary = "--61141483716826"
    contenttype = "multipart/form-data; boundary=" .. boundary
    local mes = "--".. boundary .. "\r\n"
      .."Content-Disposition: form-data; name=\"file\"; filename=\""..file_path.."\"\r\n"
      .."Content-Type: text/plain\r\n"
      .."\r\n"
      .."<!--WLANSDFILE-->\r\n"
      .."--" .. boundary .. "--\r\n"
    local blen = filesize + string.len(mes) - 17
    b,c,h = fa.request{
        url=config.api_base .. "/v1/flashairs/self/measurements/free?timestamp_type=" .. timestamp_type .. "&timestamp_unit=" .. timestamp_unit,
        method="POST",
        headers={
            ['Authorization']='Basic ' .. config.credential,
            ["Content-Length"]=tostring(blen),
            ["Content-Type"]=contenttype,
        },
        file=file_path,
        body=mes,
        bufsize=1460*10,
    }
end

config = readConfig(CONFIG_FILE)

return {
    runJob=runJob,
    addMeasurement=addMeasurement,
    addPio=addPio,
    startPioUpload=pio_create,
    stopPioUpload=pio_destroy,
    log=log,
    uploadImage=uploadImage,
    uploadFile=uploadFile,
    uploadCSV=uploadCSV,
}
