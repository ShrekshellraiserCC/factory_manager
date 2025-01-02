local function uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function(c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

---@class Node Generic Node
---@field label string?
---@field id string
---@field node_type string
---@field inputs Connector[]
---@field outputs Connector[]
---@field window Window
---@field dragging boolean
---@field drag_x integer
---@field drag_y integer
---@field locked boolean? Whether editing the connectors is allowed
---@field x integer
---@field y integer
---@field w integer
---@field h integer
local node__index = {}
local node_meta = { __index = node__index }

-- TODO finish moving this out
local disp_context = require("libs.disp_context")
local nodes_win = disp_context.nodes_win

local tick_delay = 0.1

function node__index:on_event(e)
    for i, con in ipairs(self.inputs) do
        con:on_event(e)
    end
    for _, con in ipairs(self.outputs) do
        con:on_event(e)
    end
end

--- Recalculate width/height and resize the window
function node__index:update_size()
    local w = #(self.label or "") + 2
    local h = 3
    local connection_height = math.max(#self.inputs, #self.outputs)
    if connection_height > 0 then
        h = h + 1
    end
    for i = 1, connection_height do
        local layer_w = 4
        local input, output = self.inputs[i], self.outputs[i]
        if input then
            layer_w = layer_w + #(input.label or "")
            input.y = h
        end
        if output then
            layer_w = layer_w + #(output.label or "")
            output.y = h
        end
        h = h + 2
        w = math.max(w, layer_w)
    end
    self.h = h
    self.w = w
    if self.update_window then
        self:update_window()
    end
end

function node__index:has_con(con)
    for i, v in ipairs(self.outputs) do
        if v == con then
            return true
        end
    end
    for i, v in ipairs(self.outputs) do
        if v == con then
            return true
        end
    end
    return false
end

---@param connections Connector[]
local function validate_connections(connections)
    for i, con in ipairs(connections) do
        if con.link and not con.link_parent:has_con(con.link) then
            -- this link is not valid
            con.link = nil
            con.link_parent = nil
        end
    end
end

--- Remove any invalid connections
function node__index:validate_connections()
    validate_connections(self.inputs)
    validate_connections(self.outputs)
end

---@type table<string,RegisteredNode>
local registered_nodes = {}
---@type table<string,RegisteredConnector>
local registered_connectors = {}

---Add an input connector
---@param con Connector
function node__index:add_input(con)
    con.direction = "input"
    con.parent = self
    self.inputs[#self.inputs + 1] = con
    self:update_size()
end

---Add an output connector
---@param con Connector
function node__index:add_output(con)
    con.direction = "output"
    con.parent = self
    self.outputs[#self.outputs + 1] = con
    self:update_size()
end

---@param connections Connector[]
local function unlink(connections)
    for i, con in ipairs(connections) do
        if con.link then
            con.link.link = nil
            con.link.link_parent = nil
            con.link = nil
            con.link_parent = nil
        end
    end
end

--- Delete all connections to this node
function node__index:unlink()
    unlink(self.inputs)
    unlink(self.outputs)
end

local function merge_into(from, to)
    for _, func in ipairs(from) do
        to[#to + 1] = func
    end
end

---Tick all outgoing connections of this node
---@return function[]?
function node__index:tick()
    local funcs = {}
    for _, v in ipairs(self.outputs) do
        local funcs_l = v:tick()
        merge_into(funcs_l or {}, funcs)
    end
    return funcs
end

---@class Packet

--- Transfer data to a connector on this node
---@param connector Connector
---@param packet Packet
function node__index:transfer(connector, packet)
    connector:recieve_packet(packet)
end

---@return Node
local function new_node()
    local tw, th = disp_context.nodes_win.getSize()
    local cx, cy = -disp_context.root_x + math.floor(tw / 2), -disp_context.root_y + math.floor(th / 2)
    ---@type Node
    local node = setmetatable(
        { x = cx, y = cy, inputs = {}, outputs = {}, id = uuid(), node_type = "DEFAULT" },
        node_meta)
    node.window = window.create(nodes_win, node.x, node.y, 1, 1)
    node:update_size()
    return node
end

---@class Connector
---@field sent_a_packet boolean?
---@field link Connector?
---@field link_parent Node?
---@field parent Node
---@field con_type string
---@field direction "input"|"output"
---@field label string?
---@field color color?
---@field y integer
---@field char string?
---@field id string
---@field recieve_packet fun(self:Connector,packet:Packet)
---@field tick fun(self:Connector):function[]? Run on a frequent basis
local con__index = {}

function con__index:unlink()
    if self.link then
        self.link.link = nil
        self.link.link_parent = nil
    end
    self.link = nil
    self.link_parent = nil
end

---@param node Node
---@param con Connector
function con__index:set_link(node, con)
    self.link = con
    self.link_parent = node
    con.link = self
    con.link_parent = self.parent
end

function con__index:on_event(e)

end

---Default no-op
function con__index:tick() end

---Default no-op
function con__index:recieve_packet(packet) end

local con_meta = { __index = con__index }

---Create a new default connector
---@return Connector
local function new_connector()
    local connector = {
        con_type = "DEFAULT",
        id = uuid(),
    }
    return setmetatable(connector, con_meta)
end


---@param connector Connector
---@param packet Packet
local function send_packet_to_link(connector, packet)
    connector.sent_a_packet = true
    if connector.link and connector.link_parent then
        connector.link.sent_a_packet = true
        connector.link_parent:transfer(connector.link, packet)
    end
end

local function clear_packet_recieved(node)
    for _, v in ipairs(node.inputs) do
        v.sent_a_packet = nil
    end
    for _, v in ipairs(node.outputs) do
        v.sent_a_packet = nil
    end
end


---Register a new type of connector
---@param name string
---@param new fun(): Connector
---@param serialize SerializeConFun
---@param unserialize SerializeConFun
---@param configurable_fields ConfigFieldInfo?
---@param set_field ConFieldSetter?
---@param color color
---@param char string?
local function register_connector(name, new, serialize, unserialize, configurable_fields, set_field, color, char)
    registered_connectors[name] = {
        new = new,
        serialize = serialize,
        unserialize = unserialize,
        configurable_fields = configurable_fields,
        set_field = set_field,
        color = color,
        char = char
    }
end

register_connector("DEFAULT", new_connector, function() end, function() end, nil, nil, colors.white)
---@param name string
---@return RegisteredConnector
local function get_connector(name)
    return registered_connectors[name]
end


---@alias NodeFieldSetter fun(con: Node, key: string, value: any)
---@alias SerializeNodeFun fun(con: Node)
---@alias NewNodeFun fun():Node
---@alias RegisteredNode {name:string,new:NewNodeFun,serialize:SerializeNodeFun,unserialize:SerializeNodeFun,configurable_fields:ConfigFieldInfo?,set_field:NodeFieldSetter?}


---@param name string
---@param new NewNodeFun
---@param serialize SerializeNodeFun
---@param unserialize SerializeNodeFun
---@param configurable_fields ConfigFieldInfo?
---@param set_field NodeFieldSetter?
local function register_node(name, new, serialize, unserialize, configurable_fields, set_field)
    registered_nodes[name] = {
        new = new,
        serialize = serialize,
        unserialize = unserialize,
        configurable_fields = configurable_fields,
        set_field = set_field
    }
end

register_node("DEFAULT", new_node, function() end, function() end, nil, nil)

---@param name string
---@return RegisteredNode
local function get_node(name)
    return registered_nodes[name]
end


--- Thanks 9551 https://github.com/9551-Dev/libC3D-dev/blob/dev/common/table_util.lua#L56-L85
local function deepcopy(tbl, keep, seen)
    local instance_seen = seen or {}
    local out = {}
    instance_seen[tbl] = out
    for copied_key, copied_value in pairs(tbl) do
        local is_table = type(copied_value) == "table" and not (keep and keep[copied_key])

        if type(copied_key) == "table" then
            if instance_seen[copied_key] then
                copied_key = instance_seen[copied_key]
            else
                local new_instance = deepcopy(copied_key, keep, instance_seen)
                instance_seen[copied_key] = new_instance
                copied_key = new_instance
            end
        end

        if is_table and not instance_seen[copied_value] then
            local new_instance = deepcopy(copied_value, keep, instance_seen)
            instance_seen[copied_value] = new_instance
            out[copied_key] = new_instance
        elseif is_table and instance_seen[copied_value] then
            out[copied_key] = instance_seen[copied_value]
        else
            out[copied_key] = copied_value
        end
    end

    return setmetatable(out, getmetatable(tbl))
end

---@class Serialized_Connector : Connector
---@field link string?
---@field link_parent string?
---@field parent string

---@param con Connector
local function serialize_connector(con)
    con = con --[[@as Serialized_Connector]]
    if con.link then
        con.link = con.link.id
        con.link_parent = con.link_parent.id
    end
    con.parent = con.parent.id
    registered_connectors[con.con_type].serialize(con)
end

---@param node Node
local function serialize_node(node)
    for _, con in ipairs(node.inputs) do
        serialize_connector(con)
    end
    for _, con in ipairs(node.outputs) do
        serialize_connector(con)
    end
end

local function search_for_connector_link(con_array, con)
    for _, con_child in ipairs(con_array) do
        if con_child.id == con.link then
            con.link = con_child
            return true
        end
    end
end

---@param nodes Node[] Table of nodes currently being unserialized
---@param con Connector
local function unserialize_connector(nodes, con)
    if con.link then
        for _, node in ipairs(nodes) do
            if node.id == con.link_parent then
                con.link_parent = node
                break
            end
        end
        if type(con.link_parent) == "string" then
            error(("Unable to find connector parent %s"):format(con.link_parent))
        end
        local found_link = search_for_connector_link(con.link_parent.inputs, con) or
            search_for_connector_link(con.link_parent.outputs, con)
        if not found_link then
            error(("Unable to find connector link %s"):format(con.link))
        end
    end
    if registered_connectors[con.con_type] then
        registered_connectors[con.con_type].unserialize(con)
    else
        error(("Unrecognized connectory type %s"):format(con.con_type))
    end
end

---@param nodes Node[] Table of nodes currently being unserialized
---@param node Node
local function unserialize_node(nodes, node)
    for _, con in ipairs(node.inputs) do
        con.parent = node
        unserialize_connector(nodes, con)
    end
    for _, con in ipairs(node.outputs) do
        con.parent = node
        unserialize_connector(nodes, con)
    end
    node.window = window.create(nodes_win, node.x, node.y, 1, 1)
    setmetatable(node, node_meta)
    node:update_size()
end

---@alias NodeT Node[]




local executeLimit = 128 -- limit of functions to run in parallel
---Execute a table of functions in batches
---@param func function[]
---@param skipPartial? boolean Only do complete batches and skip the remainder.
---@return function[] skipped Functions that were skipped as they didn't fit.
local function batch_execute(func, skipPartial)
    local batches = #func / executeLimit
    batches = skipPartial and math.floor(batches) or math.ceil(batches)
    for batch = 1, batches do
        local start = ((batch - 1) * executeLimit) + 1
        local batch_end = math.min(start + executeLimit - 1, #func)
        parallel.waitForAll(table.unpack(func, start, batch_end))
    end
    return table.pack(table.unpack(func, 1 + executeLimit * batches))
end

---@class Factory
local factory__index = {}

local factory_meta = { __index = factory__index }
---@param node Node
function factory__index:add_node(node)
    self.nodes[#self.nodes + 1] = node
end

---@param node Node
function factory__index:remove_node(node)
    for i, node_i in ipairs(self.nodes) do
        if node_i == node then
            table.remove(self.nodes, i)
            break
        end
    end
    unlink(node.inputs)
    unlink(node.outputs)
end

function factory__index:start_ticking()
    while true do
        sleep(tick_delay)
        if active then
            local funcs = {}
            for _, v in ipairs(self.nodes) do
                local funcs_l = v:tick()
                merge_into(funcs_l or {}, funcs)
            end
            batch_execute(funcs)
        end
    end
end

---@param e any[]
function factory__index:distribute_event(e)
    for k, v in ipairs(self.nodes) do
        if v[e[1]](v, table.unpack(e, 2, 5)) then return true end
    end
end

function factory__index:serialize()
    local serializing_nodes = deepcopy(self.nodes) --[[@as NodeT]]
    for _, node in ipairs(serializing_nodes) do
        node.window = nil
        serialize_node(node)
        if node.node_type then
            registered_nodes[node.node_type].serialize(node)
        end
    end
    return textutils.serialise(serializing_nodes, { compact = false })
end

local function new_factory()
    ---@class Factory
    local factory = {
        ---@type NodeT
        nodes = {}
    }

    return setmetatable(factory, factory_meta)
end

---@param text string
---@return Factory
local function unserialize(text)
    local unserialized_nodes = textutils.unserialise(text) --[[@as NodeT]]
    for _, node in ipairs(unserialized_nodes) do
        unserialize_node(unserialized_nodes, node)
        if node.node_type then
            registered_nodes[node.node_type].unserialize(node)
        end
    end
    local factory = new_factory()
    factory.nodes = unserialized_nodes
    return factory
end

return {
    node__index = node__index,
    node_meta = node_meta,
    con__index = con__index,
    con_meta = con_meta,
    clear_packet_recieved = clear_packet_recieved,
    send_packet_to_link = send_packet_to_link,
    registered_connectors = registered_connectors,
    registered_nodes = registered_nodes,
    new_connector = new_connector,
    get_connector = get_connector,
    new_node = new_node,
    get_node = get_node,
    unserialize = unserialize,
    register_connector = register_connector,
    register_node = register_node,
    new_factory = new_factory
}