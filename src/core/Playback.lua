Playback = {
	rom_loaded = false,
	is_saved = false,
	is_recording = false,
	recorded_start_state = false
}

local ROM_PATH = nil
local RECORDINGS = {}

local DATA_OFFSET = nil
local DATA_START_PTR = nil
local DATA_MAX_SIZE = nil

local STATE_BLOCKS <const> = {
	--         us          jp          sh          eu
	{ addr = { 0x80207700, 0x80207B00, 0x80203F00, 0x80202F00 }, size = 0x200 }, -- gSaveBuffer
	{ addr = { 0x8032D5D4, 0x8032C694, 0x8030CD04, 0x802F9784 }, size = 4 },     -- gGlobalTimer
	{ addr = { 0x8032DD34, 0x8032CDD4, 0x8030D464, 0x802F9F04 }, size = 2 },     -- sSwimStrength
	{ addr = { 0x8032DD80, 0x8032CE20, 0x8030D4B0, 0x802F9F50 }, size = 0x18 },  -- save_file.o
	{ addr = { 0x8032DDF4, 0x8032CE94, 0x8030D524, 0x802F9FC4 }, size = 2 },     -- gCurrSaveFileNum
	{ addr = { 0x8032DF08, 0x8032CFA8, 0x8030D638, 0x802FA0E8 }, size = 2 },     -- gAreaUpdateCounter
	{ addr = { 0x8032DF38, 0x8032CFD8, 0x8030D668, 0x802FA118 }, size = 4 },     -- gCurrLevelArea
	{ addr = { 0x80330F3C, 0x8032FFDC, 0x8031066C, 0x802FD0FC }, size = 4 },     -- gPaintingMarioYEntry
	{ addr = { 0x80331370, 0x80330410, 0x80310AA0, 0x802FD530 }, size = { 0x368, 0x1C0, 0x1C4, 0x670 } }, -- ingame_menu.o
	{ addr = { 0x80332614, 0x80331504, 0x80311B94, 0x802FEBC4 }, size = 2 },     -- sPrevCheckMarioRoom
	{ addr = { 0x8033B170, 0x80339E00, 0x8031D9C0, 0x80309430 }, size = 0xC8 },  -- gMarioStates[0]
	{ addr = { 0x8033B260, 0x80339EF0, 0x8031DA88, 0x803094F8 }, size = 0x0E },  -- gHudDisplay
	{ addr = { 0x8033B3B0, 0x8033A040, 0x8031DBA0, 0x80309610 }, size = 0x24 },  -- gBodyStates[0]
	{ addr = { 0x8033C61E, 0x8033B2AE, 0x8031EF32, 0x8030A9A2 }, size = 2 },     -- sAvoidYawVel
	{ addr = { 0x8033C684, 0x8033B314, 0x8031F1AC, 0x8030AC1C }, size = 2 },     -- sSelectionFlags
	{ addr = { 0x80361258, 0x8035FEE8, 0x80343418, 0x8032EE88 }, size = 2 },     -- gTTCSpeedSetting
	{ addr = { 0x8038EEE0, 0x8038EEE0, 0x8038BBC0, 0x80389C60 }, size = 2 },     -- gRandomSeed16
}

local START_STATE = {}
local PREV_FRAME_VARS = {}

local LAST_RECORDING_NAME = nil
local LAST_RECORDING_LENGTH = nil
local RECORDING_ERROR_MSG = nil
local RECORDING_FROM_LEVEL_WARP = nil

local DEFAULT_RECORDING_NAME <const> = "Unnamed Recording"

local HEADER_SIZE <const> = 32
local ADDR_BLOCK_SIZE <const> = 8
local INPUT_SIZE <const> = 12


local function get_state_blocks()
	local idx = Settings.address_source_index
	local blocks = {}
	for i = 1, #STATE_BLOCKS do
		local addr = STATE_BLOCKS[i].addr[idx]
		if addr ~= nil then
			local size = STATE_BLOCKS[i].size
			if type(size) == "table" then
				size = size[idx]
			end
			table.insert(blocks, { addr = addr, size = size })
		end
	end
	return blocks
end

local function is_playback_supported()
	return #get_state_blocks() > 0
end


local function recording_name_exists(name)
	for i=1,#RECORDINGS do
		if (RECORDINGS[i].name == name) then
			return true
		end
	end
	return false
end

local function unique_recording_name(name)
	if not recording_name_exists(name) then
		return name
	end
	local i = 2
	while true do
		local uname = string.format("%s (%d)", name, i)
		if not recording_name_exists(uname) then
			return uname
		end
		i = i + 1
	end
end


local function align(n)
	return (n + 3) & ~3
end

local function align_file(file)
	local cur = file:seek("cur")
	local offset = 4 - (cur & 3)
	if (offset ~= 4) then
		file:seek("cur", offset)
	end
end


local function get_data_size()
	local num_recs = #RECORDINGS
	local total_size = num_recs*HEADER_SIZE -- header data
	for i=1,num_recs do
		local cur_rec = RECORDINGS[i]
		local addr_blocks_size = cur_rec.mem_blocks_length*ADDR_BLOCK_SIZE
		local name_size = 0
		if (cur_rec.name ~= nil) then
			name_size = align(#cur_rec.name + 1)
		end
		local data_size = align(#cur_rec.state_data)
		local inputs_size = cur_rec.length*INPUT_SIZE
		total_size = total_size + addr_blocks_size + name_size + data_size + inputs_size
	end
	return total_size
end


local function read_s8(file)
	return string.unpack("b", file:read(1))
end

local function write_s8(file, v)
	return file:write(string.pack("b", v))
end

local function read_u8(file)
	return string.byte(file:read(1))
end

local function write_u8(file, v)
	return file:write(string.char(v))
end

local function read_s16(file)
	return string.unpack(">h", file:read(2))
end

local function write_s16(file, v)
	return file:write(string.pack(">h", v))
end

local function read_u16(file)
	return string.unpack(">H", file:read(2))
end

local function write_u16(file, v)
	return file:write(string.pack(">H", v))
end

local function read_u32(file)
	return string.unpack(">I", file:read(4))
end

local function write_u32(file, v)
	return file:write(string.pack(">I", v))
end

local function read_str(file)
	local s = ""
	while true do
		local cur = file:read(1)
		if ((cur == nil) or (cur == '\0')) then
			return s
		end
		s = s .. cur
	end
end

local function write_str(file, str)
	local s = file:seek("cur")
	if (str ~= nil) then
		file:write(str .. '\0')
	end
end


local MARKER <const> = "\90\131\177\192"
local function seek_data_start(file)
	repeat
		local m = file:read(4)
		if (m == nil) then
			return false
		end
	until (m == MARKER)
	return true
end


local function read_level_load_params(file)
	local load_params = {
		warp_type = read_u8(file),
		warp_level_num = read_u8(file),
		warp_area_idx = read_u8(file),
		warp_node_id = read_u8(file),
		warp_arg = read_u32(file),
		warp_act_num = read_s16(file),
		warp_trans_red = read_u8(file),
		warp_trans_green = read_u8(file),
		warp_trans_blue = read_u8(file)
	}
	align_file(file)
	return load_params
end

local function write_level_load_params(file, load_params)
	write_u8(file, load_params.warp_type)
	write_u8(file, load_params.warp_level_num)
	write_u8(file, load_params.warp_area_idx)
	write_u8(file, load_params.warp_node_id)
	write_u32(file, load_params.warp_arg)
	write_s16(file, load_params.warp_act_num)
	write_u8(file, load_params.warp_trans_red)
	write_u8(file, load_params.warp_trans_green)
	write_u8(file, load_params.warp_trans_blue)
	align_file(file)
end

local function read_recording_header(file)
	return {
		mem_blocks_length = read_u16(file),
		length = read_u16(file),
		level_load_params = read_level_load_params(file),
		state_mem_blocks_ptr = read_u32(file),
		state_mem_data_ptr = read_u32(file),
		inputs_ptr = read_u32(file)
	}
end

local function write_recording_header(file, header)
	write_u16(file, header.mem_blocks_length)
	write_u16(file, header.length)
	write_level_load_params(file, header.level_load_params)
	write_u32(file, header.state_mem_blocks_ptr)
	write_u32(file, header.state_mem_data_ptr)
	write_u32(file, header.inputs_ptr)
end

local function read_addr_blocks(file, addr_blocks, mem_blocks_length)
	local total_state_size = 0
	for i=1,mem_blocks_length do
		local addr_block = {
			addr = read_u32(file),
			size = read_u32(file)
		}
		table.insert(addr_blocks, addr_block)
		total_state_size = total_state_size + addr_block.size
	end
	return total_state_size
end

local function write_addr_blocks(file, addr_blocks)
	for i=1,#addr_blocks do
		local addr_block = addr_blocks[i]
		write_u32(file, addr_block.addr)
		write_u32(file, addr_block.size)
	end
end

local function read_input(file)
	return {
		b = read_u16(file),
		x = read_s8(file),
		y = read_s8(file),
		cam_yaw = read_u16(file),
		cam_movement_flags = read_s16(file),
		cam_selection_flags = read_s16(file),
		random_seed = read_u16(file)
	}
end

local function write_input(file, input)
	write_u16(file, input.b)
	write_s8(file, input.x)
	write_s8(file, input.y)
	write_u16(file, input.cam_yaw)
	write_s16(file, input.cam_movement_flags)
	write_s16(file, input.cam_selection_flags)
	write_u16(file, input.random_seed)
end


local function read_recording(file, header)
	local addr_blocks = {}
	local total_state_size = read_addr_blocks(file, addr_blocks, header.mem_blocks_length)

	-- get tas name if exists
	local data_start_offset = header.state_mem_data_ptr - header.state_mem_blocks_ptr
	local recording_name = nil
	if (data_start_offset > ADDR_BLOCK_SIZE*header.mem_blocks_length) then -- tas name written in recording data
		recording_name = read_str(file)
		align_file(file)
	end

	local state_data = file:read(total_state_size)
	align_file(file)

	local inputs = {}
	for i=1,header.length do
		local input = read_input(file)
		table.insert(inputs, input)
	end

	return {
		mem_blocks_length = header.mem_blocks_length,
		length = header.length,
		level_load_params = header.level_load_params,
		addr_blocks = addr_blocks,
		state_data = state_data,
		inputs = inputs,
		name = recording_name
	}
end


local function write_recording(file, recording)
	write_addr_blocks(file, recording.addr_blocks)

	if (recording.name ~= nil) then
		write_str(file, recording.name)
		align_file(file)
	end

	file:write(recording.state_data)
	align_file(file)

	for i=1,recording.length do
		write_input(file, recording.inputs[i])
	end
end


function Playback.load_rom()
	local path = iohelper.filediag("*.z64", 0)
	if ((path == nil) or (path == "")) then
		return
	end

	local file = io.open(path, "rb")
	if (file == nil) then
		return
	end

	if not seek_data_start(file) then
		file:close()
		return
	end

	local data_offset = file:seek("cur")
	local data_start_ptr = read_u32(file)
	local data_max_size = read_u32(file)
	local num_recs = read_u32(file)

	local headers = {}
	for i=1,num_recs do
		local header = read_recording_header(file)
		table.insert(headers, header)
	end

	RECORDINGS = {}
	for i=1,num_recs do
		local recording = read_recording(file, headers[i])
		if (recording.name == nil) then
			recording.name = unique_recording_name(DEFAULT_RECORDING_NAME)
		end
		table.insert(RECORDINGS, recording)
	end

	file:close()
	ROM_PATH = path
	DATA_OFFSET = data_offset
	DATA_START_PTR = data_start_ptr
	DATA_MAX_SIZE = data_max_size
	Playback.rom_loaded = true
	Playback.is_saved = true
end


local function build_recording_header(recording, cur_ptr)
	local state_mem_blocks_ptr = cur_ptr
	local state_mem_data_ptr = state_mem_blocks_ptr + recording.mem_blocks_length*ADDR_BLOCK_SIZE
	if (recording.name ~= nil) then
		state_mem_data_ptr = state_mem_data_ptr + align(#recording.name + 1)
	end
	local inputs_ptr = state_mem_data_ptr + align(#recording.state_data)

	cur_ptr = inputs_ptr + #recording.inputs*INPUT_SIZE

	return {
		mem_blocks_length = recording.mem_blocks_length,
		length = recording.length,
		level_load_params = recording.level_load_params,
		state_mem_blocks_ptr = state_mem_blocks_ptr,
		state_mem_data_ptr = state_mem_data_ptr,
		inputs_ptr = inputs_ptr
	}, cur_ptr
end

local function update_rom(path)
	if not Playback.rom_loaded then
		return false
	end

	local file = io.open(path, "r+b")
	if (file == nil) then
		return false
	end

	local write_start_offset = DATA_OFFSET + 8
	if (file:seek("set", write_start_offset) ~= write_start_offset) then
		file:close()
		return false
	end

	local num_recs = #RECORDINGS
	write_u32(file, num_recs)

	local s = file:seek("cur")

	local header
	local cur_ptr = DATA_START_PTR + num_recs*HEADER_SIZE -- header data
	for i=1,num_recs do
		header, cur_ptr = build_recording_header(RECORDINGS[i], cur_ptr)
		write_recording_header(file, header)
	end

	for i=1,num_recs do
		write_recording(file, RECORDINGS[i])
	end

	file:close()
	return true
end


function Playback.save_rom()
	if (get_data_size() > DATA_MAX_SIZE) then
		return
	end

	if update_rom(ROM_PATH) then
		Playback.is_saved = true
	end
end


local CHUNK_SIZE <const> = 8192
local function copy_file(dest_path, src_path)
	local src_file = io.open(src_path, "rb")
	if (src_file == nil) then
		return false
	end

	local dest_file = io.open(dest_path, "wb")
	if (dest_file == nil) then
		src_file:close()
		return false
	end

	while true do
		local chunk = src_file:read(CHUNK_SIZE)
		if (chunk == nil) then
			break
		end
		dest_file:write(chunk)
	end

	dest_file:close()
	src_file:close()
	return true
end

function Playback.save_rom_as()
	if (get_data_size() > DATA_MAX_SIZE) then
		return
	end

	local path = iohelper.filediag("*.z64", 1)
	if ((path == nil) or (path == "")) then
		return
	end

	if (path == ROM_PATH) then
		Playback.save_rom()
		return
	end

	if not copy_file(path, ROM_PATH) then
		return
	end

	if update_rom(path) then
		ROM_PATH = path
		Playback.is_saved = true
	end
end


local function filename_from_path(path)
	local start, finish = path:find('[%w%s!-={-|]+[_%.].+')
	return path:sub(start,#path)
end

function Playback.get_rom_info()
	if not Playback.rom_loaded then
		return { "ROM not loaded" }
	end

	local changesLine = "Saved"
	if not Playback.is_saved then
		changesLine = "Unsaved changes"
	end

	return {
		string.format("ROM Filename: \"%s\"", filename_from_path(ROM_PATH)),
		string.format("Num Recordings: %d", #RECORDINGS),
		string.format("Capacity: %.2f%%", 100*get_data_size()/DATA_MAX_SIZE),
		changesLine
	}
end


local function get_cam_yaw()
	local addr = Addresses[Settings.address_source_index]
	local mario_area = memory.readdword(addr.mario_states + 0x90)
	if (mario_area == 0) then
		return 0
	end
	local area_cam = memory.readdword(mario_area + 0x24)
	if (area_cam == 0) then
		return 0
	end
	return memory.readword(area_cam + 2)
end

local function update_prev_frame_vars()
	local addr = Addresses[Settings.address_source_index]
	PREV_FRAME_VARS = {
		global_timer = memory.readdword(addr.global_timer),
		cam_yaw = get_cam_yaw(),
		cam_movement_flags = memory.readwordsigned(addr.cam_movement_flags),
		cam_selection_flags = memory.readwordsigned(addr.cam_selection_flags),
		random_seed = memory.readword(addr.rng_value)
	}
end

local function add_recording_frame()
	local addr = Addresses[Settings.address_source_index]
	local global_timer = memory.readdword(addr.global_timer)
	if ((PREV_FRAME_VARS.global_timer ~= -1) and (global_timer ~= (PREV_FRAME_VARS.global_timer + 1))) then
		RECORDING_ERROR_MSG = "Global timer inconsistent"
		Playback.cancel_recording()
	end

	local input = {
		x = memory.readbytesigned(addr.controller_pads + 2),
		y = memory.readbytesigned(addr.controller_pads + 3),
		b = memory.readword(addr.controller_pads + 0),
		cam_yaw = PREV_FRAME_VARS.cam_yaw,
		cam_movement_flags = PREV_FRAME_VARS.cam_movement_flags,
		cam_selection_flags = PREV_FRAME_VARS.cam_selection_flags,
		random_seed = PREV_FRAME_VARS.random_seed
	}
	table.insert(RECORDING_INPUTS, input)
end


local MEMORY_BLOCK_READ_SIZES <const> = { 4, 2, 1 }
local function read_memory_block(addr, size)
	local data_block = ""
	for i=1,#MEMORY_BLOCK_READ_SIZES do
		local cur_read_size = MEMORY_BLOCK_READ_SIZES[i]
		while (size >= cur_read_size) do
			if (cur_read_size == 4) then
				data_block = data_block .. string.pack(">I4", memory.readdword(addr))
			elseif (cur_read_size == 2) then
				data_block = data_block .. string.pack(">I2", memory.readword(addr))
			else
				data_block = data_block .. string.pack("B", memory.readbyte(addr))
			end
			addr = addr + cur_read_size
			size = size - cur_read_size
		end
	end
	return data_block
end

local function update_start_state()
	local addr = Addresses[Settings.address_source_index]
	local load_params = {
		warp_type = memory.readbyte(addr.warp_dest + 0),
		warp_level_num = memory.readbyte(addr.warp_dest + 1),
		warp_area_idx = memory.readbyte(addr.warp_dest + 2),
		warp_node_id = memory.readbyte(addr.warp_dest + 3),
		warp_arg = memory.readdword(addr.warp_dest + 4),
		warp_act_num = memory.readwordsigned(addr.warp_act_num),
		warp_trans_red = memory.readbyte(addr.warp_trans_red),
		warp_trans_green = memory.readbyte(addr.warp_trans_green),
		warp_trans_blue = memory.readbyte(addr.warp_trans_blue)
	}

	local state_blocks = get_state_blocks()
	local state_data = ""
	for i=1,#state_blocks do
		local addr_block = state_blocks[i]
		state_data = state_data .. read_memory_block(addr_block.addr, addr_block.size)
	end

	START_STATE = {
		level_load_params = load_params,
		state_data = state_data
	}
end

local function check_recording_start()
	if (START_STATE.level_load_params ~= nil) then
		local warp_type = START_STATE.level_load_params.warp_type
		local warp_dest_type = memory.readbyte(Addresses[Settings.address_source_index].warp_dest)
		if ((warp_type ~= 0) and (warp_dest_type == 0)) then -- level or area warp
			RECORDING_FROM_LEVEL_WARP = (warp_type == 1)
			Playback.recorded_start_state = true
			add_recording_frame()
			return
		end
	end
	update_start_state()
end


function Playback.at_input()
	if Playback.is_recording then
		if not is_playback_supported() then
			RECORDING_ERROR_MSG = "Playback not supported for this version"
			Playback.cancel_recording()
			return
		end

		if Playback.recorded_start_state then
			add_recording_frame()
		else
			check_recording_start()
		end
		update_prev_frame_vars()
	end
end


function Playback.start_recording()
	if not is_playback_supported() then
		RECORDING_ERROR_MSG = "Playback not supported for this version"
		return
	end
	RECORDING_ERROR_MSG = nil

	START_STATE = {}
	PREV_FRAME_VARS = {}
	RECORDING_INPUTS = {}

	Playback.recorded_start_state = false
	Playback.is_recording = true
end

function Playback.cancel_recording()
	Playback.is_recording = false
end

function Playback.stop_recording()
	local recording_length = #RECORDING_INPUTS
	if (recording_length == 0) then
		Playback.cancel_recording()
		return
	elseif (recording_length >= 65536) then
		RECORDING_ERROR_MSG = "Recording too long"
		Playback.cancel_recording()
		return
	end

	Playback.is_recording = false

	local recording_name = input.prompt("Enter recording name:")
	if ((recording_name == nil) or (recording_name == "")) then
		recording_name = DEFAULT_RECORDING_NAME
	end
	recording_name = unique_recording_name(recording_name)

	local state_blocks = get_state_blocks()
	local recording = {
		mem_blocks_length = #state_blocks,
		length = recording_length,
		level_load_params = START_STATE.level_load_params,
		addr_blocks = state_blocks,
		state_data = START_STATE.state_data,
		inputs = RECORDING_INPUTS,
		name = recording_name
	}
	table.insert(RECORDINGS, recording)
	LAST_RECORDING_NAME = recording_name
	LAST_RECORDING_LENGTH = recording_length
	Playback.is_saved = false
end


function Playback.get_recording_info()
	local state_str = "Not recording"
	local length = 0

	if Playback.is_recording then
		length = #RECORDING_INPUTS
		if Playback.recorded_start_state then
			if RECORDING_FROM_LEVEL_WARP then
				state_str = "Recording inputs"
			else
				state_str = "Warning: Area transition may desync"
			end
		else
			state_str = "Waiting for area transition"
		end
	elseif (RECORDING_ERROR_MSG ~= nil) then
		state_str = "Error: " .. RECORDING_ERROR_MSG
	elseif (LAST_RECORDING_NAME ~= nil) then
		state_str = string.format("Recorded \"%s\"", LAST_RECORDING_NAME)
		length = LAST_RECORDING_LENGTH
	end

	return {
		state_str,
		string.format("Length: %d", length)
	}
end


function Playback.get_recording_names()
	local recording_names = {}
	for i=1,#RECORDINGS do
		table.insert(recording_names, RECORDINGS[i].name)
	end
	return recording_names
end


function Playback.move_recording_up(i)
	local j = i - 1
	RECORDINGS[i], RECORDINGS[j] = RECORDINGS[j], RECORDINGS[i]
end

function Playback.move_recording_down(i)
	local j = i + 1
	RECORDINGS[i], RECORDINGS[j] = RECORDINGS[j], RECORDINGS[i]
end

function Playback.delete_recording(i)
	table.remove(RECORDINGS, i)
	Playback.is_saved = false
end

function Playback.rename_recording(i)
	local recording_name = input.prompt("Enter recording name:")
	if ((recording_name == nil) or (recording_name == "")) then
		return
	end

	local recording = RECORDINGS[i]
	if (recording_name == recording.name) then
		return
	end
	recording.name = nil
	recording.name = unique_recording_name(recording_name)
	Playback.is_saved = false
end


function Playback.save_recording(i)
	local path = iohelper.filediag("*.dat", 1)
	if ((path == nil) or (path == "")) then
		return
	end

	local file = io.open(path, "wb")
	if (file == nil) then
		return
	end

	local recording = RECORDINGS[i]

	write_level_load_params(file, recording.level_load_params)

	write_u16(file, recording.mem_blocks_length)
	write_addr_blocks(file, recording.addr_blocks)
	file:write(recording.state_data)

	write_u16(file, recording.length)
	for i=1,recording.length do
		write_input(file, recording.inputs[i])
	end

	if (recording.name ~= nil) then
		write_str(file, recording.name)
	end

	file:close()
end


function Playback.load_recording(i)
	local path = iohelper.filediag("*.dat", 0)
	if ((path == nil) or (path == "")) then
		return
	end

	local file = io.open(path, "rb")
	if (file == nil) then
		return
	end

	local level_load_params = read_level_load_params(file)

	local mem_blocks_length = read_u16(file)
	local addr_blocks = {}
	local total_size = read_addr_blocks(file, addr_blocks, mem_blocks_length)
	local state_data = file:read(total_size)

	local recording_length = read_u16(file)
	local inputs = {}
	for i=1,recording_length do
		local input = read_input(file)
		table.insert(inputs, input)
	end

	local recording_name = read_str(file)

	file:close()

	if ((recording_name == nil) or (recording_name == "")) then
		recording_name = DEFAULT_RECORDING_NAME
	end
	recording_name = unique_recording_name(recording_name)

	local recording = {
		mem_blocks_length = mem_blocks_length,
		length = recording_length,
		level_load_params = level_load_params,
		addr_blocks = addr_blocks,
		state_data = state_data,
		inputs = inputs,
		name = recording_name
	}
	table.insert(RECORDINGS, recording)
	Playback.is_saved = false
end
