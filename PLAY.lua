local http = require("socket.http")
local json = require("dkjson")
local ltn12 = require("ltn12")
local ffi = require("ffi")
local board = require("board")
local Heap = require 'Peaque'

-- allows us to use C std lib's Sleep(Windows)/Poll(osx/linux) function!
ffi.cdef[[
void Sleep(int ms);
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
]]

local sleep
if ffi.os == "Windows" then
  function sleep(ms)
    ffi.C.Sleep(ms)
  end
else
  function sleep(ms)
    ffi.C.poll(nil, 0, ms)
  end
end

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

-- http request handler
local function httpRequest(url, method, header, data)
    --handle when no data is sent in
    local data = data or ""

    -- encode data as a json string
    local jsonString = json.encode(data)
    local source = ltn12.source.string(jsonString)

    -- create a response table
    local response = {}
    local save = ltn12.sink.table(response)

    -- add datasize to header
    local jsonsize = #jsonString
    local sizeHeader = header
    sizeHeader["content-length"] = jsonsize

    -- REQUEST IT!
    ok, code, headers = http.request{url = url, method = method, headers = sizeHeader, source = source, sink = save}

    if code ~= 200 then
        print("Error Code:", code, table.concat(response, "\n\n\n"))
        print(url)
        print(jsonString)
        sleep(4000)
    end

    return json.decode(table.concat(response))
end

local ant = class()
function ant:__init(x, y)
    self.x = x
    self.y = y
    self.status = nil --"defend", "explore", "gather", or "follow"
    self.direction = nil --"left", "right", "up", "down"
    self.destinationX = nil
    self.destinationY = nil
end

function ant:dist2(x, y)
    local dx, dy = (self.x - x), (self.y - y)
    return dx * dx + dy * dy
end

local food = class()
function food:__init(x, y)
    self.x = x
    self.y = y
    self.nearestAnt = nil
end

local enemyHill = class()
function enemyHill:__init(x, y)
    self.x = x
    self.y = y
end

-- initialize a client class
local client = class()
function client:__init(name, url)
    self.pendingMoves = {} -- sample { {antId = 1, direction = "left"}, {antId = 2, direction = "right"} }
    self.headers = {["Accept"] = "application/json", ["Content-Type"] = "application/json"}
    self.GameId = nil
    self.url = url
    self.timeToNextTurn = 0
    self.AuthToken = nil
    self.name = name
    self.board = nil
    self.ants = {}
    self.food = {}
    self.enemyHill = {}
end

function client:logon()
    local logon = { ["GameID"] = json.null, ["AgentName"] = self.name}
    local response = httpRequest(self.url .. "/api/game/logon", "POST", self.headers, logon)
    self.AuthToken = response.AuthToken
    self.GameId = response.GameId
    print("GameId", self.GameId)
end

function client:getTurnInfo()
    local turnInfo = string.format("/api/game/%d/turn",  self.GameId)
    local response = httpRequest(self.url .. turnInfo, "GET", self.headers)
    print(response.MillisecondsUntilNextTurn, "ms left")
    self.timeToNextTurn = response.MillisecondsUntilNextTurn
end

function client:getGameInfo()
    local game = string.format("/api/game/%d/status/%s", self.GameId, self.AuthToken)
    local data = httpRequest(self.url .. game, "POST", self.headers)
    self.timeToNextTurn = data.MillisecondsUntilNextTurn
    --[[return GameStatus:new(data.IsGameOver, data.Status, data.GameId, data.Turn, data.TotalFood,
            self.__parse_hill(data.Hill), data.FogOfWar, data.MillisecondsUntilNextTurn,
            friendly_ants, enemy_ants, enemy_hills, visible_food, data.Walls, data.Width, data.Height)--]]
    return data
end

function client:updateBoard(gameState)
    -- HOME (may not be fully accurate as ants do spawn atop it)
    local myHill = gameState.Hill
    self.board.cells[myHill.X+1][myHill.Y+1].type = "myHill"

    -- will store a wall exists
    for i = 1, #gameState.Walls do
        local currentWall = gameState.Walls[i]
        self.board.cells[currentWall.X+1][currentWall.Y+1].type = "wall"
    end

    -- food bitches!
    for i = 1, #gameState.VisibleFood do
        local currentFood = gameState.VisibleFood[i]
        self.food[i] = food:new(currentFood.X+1, currentFood.Y+1)
        self.board.cells[currentFood.X+1][currentFood.Y+1].type = "food"
    end

    -- enemy ants!
    for i = 1, #gameState.EnemyAnts do
        local currentEnemy = gameState.EnemyAnts[i]
        self.board.cells[currentEnemy.X+1][currentEnemy.Y+1].type = "enemy"
    end

    -- THE ENEMY HILL(s?)
    for i= 1, #gameState.EnemyHills do
        local currentHill = gameState.EnemyHills[i]
        self.board.cells[currentHill.X+1][currentHill.Y+1].type = "enemyHill"
        self.enemyHill[i] = enemyHill:new(currentHill.X+1, currentHill.Y+1)
    end

    -- GO through and create/update a bunch of ants
    for k = 1, #gameState.FriendlyAnts do

        -- VARS on VARS YO
        local currentBoardAnt = gameState.FriendlyAnts[k]
        local currentAntId = currentBoardAnt.Id
        local currentAnt = self.ants[currentAntId]

        -- so if the ant exists
        if currentAnt and currentAnt.status ~= nil then

            -- update its position
            currentAnt.x = currentBoardAnt.X+1
            currentAnt.y = currentBoardAnt.Y+1

            -- if destination is not food, we can try to find something new
            if currentAnt.status == "gather" then
                local destType = self.board.cells[currentAnt.destinationX][currentAnt.destinationY].type
                if destType ~= "food" then
                    currentAnt.status = nil
                end
            end

        -- the ant doesn't exist
        else
            --create it and set it as the current ant
            self.ants[currentAntId] = ant:new(currentBoardAnt.X+1, currentBoardAnt.Y+1)
            currentAnt = self.ants[currentAntId]
        end

        -- update the board
        self.board.cells[currentAnt.x][currentAnt.y].type = "ant"
    end

    -- setup a defense
    -- (for now: .25 of the ants will ant dance around the base)
    local antsToDance = math.ceil(.25 * #gameState.FriendlyAnts)
    local smallestAnts = Heap()
    local currentlyDancing = 0
    for j, ant in pairs(self.ants) do
        if ant.status == "DANCE" then
            currentlyDancing = currentlyDancing + 1
        else
            smallestAnts:push(ant, self.board:dist2(ant.x, ant.y, myHill.X+1, myHill.Y+1))
        end
    end

    -- pop off the nearest quarter and let them DANCE
    antsToDance = antsToDance - currentlyDancing
    if antsToDance > 1 then
        local thriller
        for i = 1, antsToDance do
            thriller = smallestAnts:pop()
            thriller.status = "DANCE"
        end
    end

    -- collect all the nearest food.
    for i = 1, #self.food do
        local shortestDistance = math.huge
        local nearestAnt = nil
        for j, ant in pairs(self.ants) do
            local antDist = self.board:dist2(ant.x, ant.y, self.food[i].x, self.food[i].y)
            if antDist < shortestDistance then
                shortestDistance = antDist
                nearestAnt = ant
            end
        end
        if shortestDistance ~= math.huge and nearestAnt.status == nil then
            -- self.board.cells[foodX][foodY].type = "finalDestination"
            nearestAnt.status = "gather"
            nearestAnt.destinationX = self.food[i].x
            nearestAnt.destinationY = self.food[i].y
        end
    end

    for i = 1, #self.enemyHill do
        local shortestDistance = math.huge
        local nearestAnt = nil
        for j, ant in pairs(self.ants) do
            local antDist = self.board:dist2(ant.x, ant.y, self.enemyHill[i].x, self.enemyHill[i].y)
            if antDist < shortestDistance then
                shortestDistance = antDist
                nearestAnt = ant
            end
        end
        if shortestDistance ~= math.huge and nearestAnt.status == nil then
            -- self.board.cells[foodX][foodY].type = "finalDestination"
            nearestAnt.status = "gather"
            nearestAnt.destinationX = self.enemyHill[i].x
            nearestAnt.destinationY = self.enemyHill[i].y
        end
    end

    -- if #gameState.FriendlyAnts > 5 then
    --     for i= 1, #gameState.EnemyHills do
    --         local currentHill = gameState.EnemyHills[i]
    --         self.board.cells[currentHill.X+1][currentHill.Y+1].type = "enemyHill"
    --         for k = 1, #gameState.FriendlyAnts do
    --             local currentAnt = gameState.FriendlyAnts[k]
    --             self.ants[currentAnt.Id].status = "attack"
    --             self.ants[currentAnt.Id].destinationX = currentHill.X+1
    --             self.ants[currentAnt.Id].destinationY = currentHill.Y+1
    --         end
    --     end
    -- end

    for j = 1, gameState.Height do
        local herp = ""
        for i = 1, gameState.Width do
            local currentCell = self.board.cells[i][j]
            if currentCell.type == "ant" then
                herp = herp .. "A "
            else
                herp = herp .. self.board.cells[i][j].approachability .. " "
            end
        end
        -- print(herp)
    end

end

function client:update(gameState)

    -- OH BOY
    if self.board == nil then
        self.board = board:new(gameState.Width, gameState.Height)
    end

    self:getTurnInfo()

    -- create a distribution of places that need to be visited
    for i = 1, gameState.Width do
        for j = 1, gameState.Height do
            self.board.cells[i][j].approachability = self.board.cells[i][j].approachability + 1
        end
    end

    -- figure out that hive mind map!
    self:updateBoard(gameState)

    -- update turn info
    self:getTurnInfo()

    local random = {"left", "right", "up", "down"}

    for i = 1, #gameState.FriendlyAnts do
        local currentId = gameState.FriendlyAnts[i].Id
        local currentAnt = self.ants[currentId]
        local crazyRandom

        if currentAnt.status == nil then
            local firstFree = self.board:findFirstAvailable(currentAnt.x, currentAnt.y, math.random(4))
            crazyRandom = firstFree
        elseif currentAnt.status == "gather" then
            local path = self.board:aStar(currentAnt.x, currentAnt.y, currentAnt.destinationX, currentAnt.destinationY)

            if path == nil or path[1] == nil then 
                currentAnt.status = nil 
                currentAnt.destinationX = nil
                currentAnt.destinationY = nil
                crazyRandom = self.board:findFirstAvailable(currentAnt.x, currentAnt.y, math.random(4))
            else
                crazyRandom = path[1]
            end
        end

        if crazyRandom ~= nil then
            self.board:updateAntPosition(currentAnt.x, currentAnt.y, crazyRandom)
            self.pendingMoves [ #self.pendingMoves+1 ] = {antId = currentId, direction = random[crazyRandom]}
        end

    end

    self.board:clear()

end

function client:sendUpdate()
    local update = { AuthToken = self.AuthToken, GameId = self.GameId, MoveAntRequests = self.pendingMoves }
    local response = httpRequest(self.url .. "/api/game/update", "POST", self.headers, update)
    return response
end

function client:start()
    self:logon()
    local isRunning = true
    
    while isRunning do
        print("NEW TURN")
        local gameState = self:getGameInfo()
        if gameState.IsGameOver then
            isRunning = false
            print("the game is supposedly over")
            print(gameState.Status)
            break
        end
        self:update(gameState)
        self:sendUpdate()
        self.pendingMoves = {}
        self.food = {}
        if self.timeToNextTurn > 0 then
            sleep(self.timeToNextTurn)
        end
    end

end

local derp = client:new("Fretabladid", "http://antsgame.azurewebsites.net")
-- local derp = client:new("Fretabladid", "http://localhost:16901")
derp:start()
