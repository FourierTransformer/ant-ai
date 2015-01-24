local Heap = require 'Peaque'

-- Internal class constructor
local class = function(...)
    local klass = {}
    klass.__index = klass
    klass.__call = function(_,...) return klass:new(...) end
    function klass:new(...)
        local instance = setmetatable({}, klass)
        klass.__init(instance, ...)
        return instance
    end
    return setmetatable(klass,{__call = klass.__call})
end

local cell = class()
function cell:__init(x, y, id)
    self.x = x
    self.y = y
    self.type = nil
    self.neighbors = {}
    self.Id = id
    self.antId = nil
    -- the higher this value, the more we need to go there!
    self.approachability = 0
end

local board = class()
function board:__init(width, height)
    self.cells = {}
    self.width = width
    self.height = height
    
    -- initialize all the cells
    for i = 1, width do
        self.cells[i] = {}
        for j = 1, height do
            self.cells[i][j] = cell:new(i, j, (j-1)*self.width+i)
        end
    end

    -- cool, now setup pointers for the neighbors
    --(remember, you can't create a pointer to an object that doesn't exist!)
    for y = 1, height do
        for x = 1, width do
            if x == 1 then
                self.cells[x][y].neighbors[1] = self.cells[width][y]
                self.cells[x][y].neighbors[2] = self.cells[x+1][y]
            elseif x == width then
                self.cells[x][y].neighbors[1] = self.cells[x-1][y]
                self.cells[x][y].neighbors[2] = self.cells[1][y]
            else
                self.cells[x][y].neighbors[1] = self.cells[x-1][y]
                self.cells[x][y].neighbors[2] = self.cells[x+1][y]
            end

            if y == 1 then
                self.cells[x][y].neighbors[3] = self.cells[x][height]
                self.cells[x][y].neighbors[4] = self.cells[x][y+1]
            elseif y == height then
                self.cells[x][y].neighbors[3] = self.cells[x][y-1]
                self.cells[x][y].neighbors[4] = self.cells[x][1]
            else
                self.cells[x][y].neighbors[3] = self.cells[x][y-1]
                self.cells[x][y].neighbors[4] = self.cells[x][y+1]
            end
        end
    end

end

function board:updateAntPosition(x, y, direction)
    if self.cells[x][y].type == "ant" then
        self.cells[x][y].type = nil
        if direction == "right" then
            if x == self.width then
                self.cells[1][y].type = "ant"
            else
                self.cells[x+1][y].type = "ant"
            end
        elseif direction == "left" then
            if x == 1 then
                self.cells[self.width][y].type = "ant"
            else
                self.cells[x-1][y].type = "ant"
            end
        elseif direction == "up" then
            if y == 1 then
                self.cells[x][self.height].type = "ant"
            else
                self.cells[x][y-1].type = "ant"
            end
        elseif direction == "down" then
            if y == self.height then
                self.cells[x][1].type = "ant"
            else
                self.cells[x][y+1].type = "ant"
            end
        end
    else
        print("Current Type:", self.cells[x][y].type)
        -- error("OH MAN, you tried updating a position of something that wasn't an ant...")
    end

end

function board:checkFutureType(x, y, direction)
    if direction == "right" then
        if x == self.width then
            return self.cells[1][y].type
        else
            return self.cells[x+1][y].type
        end
    elseif direction == "left" then
        if x == 1 then
            return self.cells[self.width][y].type
        else
            return self.cells[x-1][y].type
        end
    elseif direction == "up" then
        if y == 1 then
            return self.cells[x][self.height].type
        else
            return self.cells[x][y-1].type
        end
    elseif direction == "down" then
        if y == self.height then
            return self.cells[x][1].type
        else
            return self.cells[x][y+1].type
        end
    end
end

function board:clear()
    for i = 1, self.width do
        for j = 1, self.height do
            self.cells[i][j].type = nil
            self.cells[i][j].id = nil
        end
    end
end

local function dist2(startX, startY, endX, endY)
  local dx, dy = (startX - endX), (startY - endY)
  return dx * dx + dy * dy
end

local function constructPath(cameFrom, cameFromDirection, currentNode)
    local final  = {}
    while cameFrom[currentNode] ~= nil do
        table.insert(final, 1, cameFromDirection[currentNode])
        currentNode = cameFrom[currentNode]
    end
    -- for i,v in ipairs(final) do print(i, v) end
    print("derp", table.concat(final, ","))
    return final
end

function board:aStar(startX, startY, endX, endY)
    local closedList = {}
    local openList = Heap()
    local cameFrom = {}
    local cameFromDirection = {}
    local linkCost = {}
    for i = 1, self.width do
        for j = 1, self.height do
            linkCost[self.cells[i][j].Id] = math.huge
        end
    end

    openList:push(self.cells[startX][startY], dist2(startX, startY, endX, endY))
    linkCost[self.cells[startX][startY].Id] = 0

    while openList:isEmpty() == false do

        local current = openList:pop()
        -- WE MADE IT
        if current.x == endX and current.y == endY then
            return constructPath(cameFrom, cameFromDirection, self.cells[endX][endY])
        end
        closedList[current.Id] = true
        for i = 1, #current.neighbors do
            local neighbor = current.neighbors[i]
            if closedList[neighbor.Id] == nil and neighbor.type ~= "wall" and neighbor.type ~= "ant" then

                local tentLinkCost = linkCost[current.Id] + dist2(current.x, current.y, neighbor.x, neighbor.y)

                if linkCost[neighbor.Id] == math.huge or tentLinkCost < linkCost[neighbor.Id] then
                    cameFrom[neighbor] = current
                    cameFromDirection[neighbor] = i
                    linkCost[neighbor.Id] = tentLinkCost
                    local totalCost = linkCost[neighbor.Id] + dist2(neighbor.x, neighbor.y, endX, endY)
                    openList:push(neighbor, totalCost)
                end

            end
        end

    end

    print("no path found...")

end

return board