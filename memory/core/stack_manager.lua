-- stack_manager.lua
-- Stack memory management with frame support

local Constants = require("memory.utils.constants")

local StackManager = {}
StackManager.__index = StackManager

-- Initialize stack manager
function StackManager:new(memory_pool, base_address, stack_size)
    local manager = {
        pool = memory_pool,
        base = base_address or Constants.MEMORY_REGIONS.STACK.base,
        size = stack_size or Constants.MEMORY_REGIONS.STACK.size,
        top = nil,  -- Stack grows downward
        frames = {},  -- Call frame stack
        current_frame = nil,
        max_depth = 0,
        push_count = 0,
        pop_count = 0
    }

    -- Initialize stack pointer to top of stack region
    manager.top = manager.base + manager.size

    setmetatable(manager, StackManager)
    return manager
end

-- Push data onto stack
function StackManager:push(size_bytes, alignment)
    alignment = alignment or Constants.ALIGNMENT.DEFAULT

    -- Align size
    size_bytes = bit32.band((size_bytes + alignment - 1), bit32.bnot(alignment - 1))

    -- Align stack pointer
    self.top = bit32.band(self.top, bit32.bnot(alignment - 1))

    -- Check for stack overflow
    if self.top - size_bytes < self.base then
        error(string.format(
            "Stack overflow: current=%d, requested=%d, available=%d",
            self.top - self.base, size_bytes, self.top - self.base
        ))
    end

    -- Allocate stack space
    self.top = self.top - size_bytes
    self.push_count = self.push_count + 1

    -- Clear allocated space
    self.pool:clear(self.top, size_bytes)

    return self.top
end

-- Pop data from stack
function StackManager:pop(size_bytes)
    -- Check for stack underflow
    if self.top + size_bytes > self.base + self.size then
        error("Stack underflow")
    end

    self.top = self.top + size_bytes
    self.pop_count = self.pop_count + 1
end

-- Enter new stack frame
function StackManager:enter_frame(frame_size)
    -- Save current frame
    local frame = {
        saved_top = self.top,
        frame_base = self.top,
        parent = self.current_frame,
        local_size = 0
    }

    -- Allocate frame space if specified
    if frame_size and frame_size > 0 then
        frame.frame_base = self:push(frame_size)
        frame.local_size = frame_size
    end

    -- Update frame tracking
    table.insert(self.frames, frame)
    self.current_frame = frame

    -- Track maximum depth
    if #self.frames > self.max_depth then
        self.max_depth = #self.frames
    end

    return frame.frame_base
end

-- Leave current stack frame
function StackManager:leave_frame()
    if not self.current_frame then
        error("No active frame to leave")
    end

    -- Restore stack pointer
    self.top = self.current_frame.saved_top

    -- Remove frame from stack
    table.remove(self.frames)
    self.current_frame = self.frames[#self.frames]
end

-- Allocate local variable in current frame
function StackManager:allocate_local(size_bytes, alignment)
    if not self.current_frame then
        error("No active frame for local allocation")
    end

    local address = self:push(size_bytes, alignment)
    self.current_frame.local_size = self.current_frame.local_size + size_bytes

    return address
end

-- Get current stack usage
function StackManager:get_usage()
    return self.base + self.size - self.top
end

-- Get available stack space
function StackManager:get_available()
    return self.top - self.base
end

-- Check if address is within stack bounds
function StackManager:is_stack_address(address)
    return address >= self.base and address < self.base + self.size
end

-- Get stack statistics
function StackManager:get_statistics()
    return {
        stack_size = self.size,
        stack_used = self:get_usage(),
        stack_available = self:get_available(),
        current_depth = #self.frames,
        max_depth = self.max_depth,
        push_count = self.push_count,
        pop_count = self.pop_count,
        stack_top = self.top,
        stack_base = self.base
    }
end

return StackManager