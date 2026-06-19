-- Thin HTTP helpers around PerformHttpRequest, exposed as CTQ.post / CTQ.log.
CTQ = CTQ or {}

function CTQ.log(...)
	if Config.Debug then
		print('[CTQBridge]', ...)
	end
end

function CTQ.warn(...)
	print('[CTQBridge] WARN:', ...)
end

-- POST JSON to `Config.Endpoint .. path`. Calls cb(ok, data) where `data` is the
-- decoded JSON body (or nil). Authenticated with the configured API key.
function CTQ.post(path, body, cb)
	local url = Config.Endpoint .. path
	PerformHttpRequest(url, function(status, text, _headers)
		local ok = status >= 200 and status < 300
		local data = nil
		if text and #text > 0 then
			local parsed = pcall(function() return json.decode(text) end) and json.decode(text) or nil
			data = parsed
		end
		if not ok then
			CTQ.warn(('POST %s -> %s %s'):format(path, status, text or ''))
		end
		if cb then cb(ok, data) end
	end, 'POST', json.encode(body or {}), {
		['Content-Type'] = 'application/json',
		['Authorization'] = 'Bearer ' .. Config.ApiKey,
	})
end
