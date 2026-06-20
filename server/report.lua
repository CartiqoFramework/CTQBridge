-- In-game /report (job 8). A player runs `/report [player_id] [reason]`; we gather
-- context and POST it to the dashboard, which persists the report and mirrors it
-- to the configured Discord channel with staff quick-action buttons.
CTQ = CTQ or {}

local function msg(src, text)
	TriggerClientEvent('chat:addMessage', src, { args = { text } })
end

RegisterCommand('report', function(source, args)
	if source == 0 then
		print('[CTQBridge] /report is an in-game command.')
		return
	end
	if #args < 2 then
		msg(source, '^1Usage: /report [player_id] [reason]')
		return
	end

	local targetId = tonumber(args[1])
	if not targetId or not GetPlayerName(targetId) then
		msg(source, '^1Player not found.')
		return
	end

	local reason = table.concat(args, ' ', 2)
	local context = {
		reporterName = GetPlayerName(source),
		targetName = GetPlayerName(targetId),
		targetIdentifiers = GetPlayerIdentifiers(targetId),
		serverTime = os.date('%Y-%m-%d %H:%M:%S'),
		playerCount = #GetPlayers(),
	}

	local reporterId = (GetPlayerIdentifiers(source) or {})[1]
	local targetIdentifier = (GetPlayerIdentifiers(targetId) or {})[1]
	if not targetIdentifier then
		msg(source, '^1Could not resolve that player’s identifier.')
		return
	end

	CTQ.post('/report', {
		reporterIdentifier = reporterId,
		targetIdentifier = targetIdentifier,
		reason = reason,
		context = context,
	}, function(ok)
		if ok then
			msg(source, '^2Your report has been submitted. Staff have been notified.')
		else
			msg(source, '^1Could not submit your report right now — please try again shortly.')
		end
	end)
end, false)
