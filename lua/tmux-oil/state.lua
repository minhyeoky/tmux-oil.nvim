-- The single buffer's state; S is replaced, never mutated in place: read state.S at call time.
local M = {}

-- Single buffer: { buf, state, rendered, own_id, own_session, popup, show_cwd, client,
--   origin = { session, window }, follow_last, touched = { [session_id] = active window },
--   confirmed }
M.S = nil

return M
