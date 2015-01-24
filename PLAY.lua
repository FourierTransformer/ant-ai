local http = require("socket.http")
local json = require("dkjson")
local ltn12 = require("ltn12")
local ffi = require("ffi")
local board = require("board")

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
        print("ruh roh", code, table.concat(response, "\n\n\n"))
        error("THE PLAYGROUND EXPLODED RUN AWAYYYYYYYYY!!!!!!!!")
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

function ant:determineDirection(destX, destY)
    if destX-self.x == 1 then return "right"
    elseif self.x-destX == 1 then return "left"
    elseif destY-self.y == 1 then return "up"
    elseif self.y-destY == 1 then return "down"
    elseif self.x-destX < 0 then return "left" --WRAPAROUND
    elseif self.x-destX > 0 then return "right" --JUMP ON IT
    elseif self.y-destY < 0 then return "down"
    elseif self.y-destY > 0 then return "up"
    end
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
    end

    for k = 1, #gameState.FriendlyAnts do
        local currentAnt = self.ants[gameState.FriendlyAnts[k].Id]
        if currentAnt and currentAnt.status ~= nil then
            self.board.cells[currentAnt.destinationX][currentAnt.destinationY].type = "finalDestination"
        end
    end

    -- will store my ants
    for k = 1, #gameState.FriendlyAnts do
        local currentAnt = gameState.FriendlyAnts[k]
        self.board.cells[currentAnt.X+1][currentAnt.Y+1].type = "ant"
        -- self.board.cells[currentAnt.X+1][currentAnt.Y+1].antId = currentAnt.Id
        if self.ants[currentAnt.Id] == nil then
            self.ants[currentAnt.Id] = ant:new(currentAnt.X+1, currentAnt.Y+1)
        else
            self.ants[currentAnt.Id].x = currentAnt.X+1
            self.ants[currentAnt.Id].y = currentAnt.Y+1
        end

        -- poor man's really fast BFS (top)
        local distanceToFood = math.huge
        local foodX, foodY = nil, nil
        for j = 10, 0, -1 do
            for i = -(10-j), 10-j do
                local x = (currentAnt.X+1+i)
                x = x % gameState.Width + 1
                local y = (currentAnt.Y+1+j)
                y = y % gameState.Height + 1
                self.board.cells[x][y].approachability = 0

                --MAYBE we'll find some foods
                if self.board.cells[x][y].type == "food" then
                    local foodDist = j + math.abs(i)
                    if foodDist < distanceToFood then
                        distanceToFood = foodDist
                        foodX = x
                        foodY = y
                    end
                end

            end
        end

        -- poor man's BFS (bottom)
        for j = -10, -1, 1 do
            for i = -(10+j), 10+j do
                local x = (currentAnt.X+1+i)
                x = x % gameState.Width + 1
                local y = (currentAnt.Y+1+j)
                y = y % gameState.Height + 1
                self.board.cells[x][y].approachability = 0

                --MAYBE we'll find some foods
                if self.board.cells[x][y].type == "food" then
                    local foodDist = j + math.abs(i)
                    if foodDist < distanceToFood then
                        distanceToFood = foodDist
                        foodX = x
                        foodY = y
                    end
                end

            end
        end

        if distanceToFood ~= math.huge and self.ants[currentAnt.Id].status == nil then
            self.board.cells[foodX][foodY].type = "finalDestination"
            self.ants[currentAnt.Id].status = "gather"
            self.ants[currentAnt.Id].destinationX = foodX
            self.ants[currentAnt.Id].destinationY = foodY
        end

        -- print("path length", #path)

    end

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
        print(herp)
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
        local currentAnt = gameState.FriendlyAnts[i]
        local crazyRandom
        local future

        if self.ants[currentAnt.Id].status == nil then
            repeat
                crazyRandom = random[math.random(4)]
                future = self.board:checkFutureType(currentAnt.X+1, currentAnt.Y+1, crazyRandom)
                print(future)
            until future ~= "ant" and future ~= "wall"
            self.board:updateAntPosition(currentAnt.X+1, currentAnt.Y+1, crazyRandom)
        else
            local path = self.board:aStar(self.ants[currentAnt.Id].x, self.ants[currentAnt.Id].y, self.ants[currentAnt.Id].destinationX, self.ants[currentAnt.Id].destinationY)
            if path == nil then 
                self.ants[currentAnt.Id].status = nil 
                crazyRandom = random[1]
            else
                crazyRandom = random[path[1]]
            end
        end

        self.board:updateAntPosition(currentAnt.X+1, currentAnt.Y+1, crazyRandom)
        self.pendingMoves [ i ] = {antId = currentAnt.Id, direction = crazyRandom}
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
        if self.timeToNextTurn > 0 then
            sleep(self.timeToNextTurn)
        end
    end

end

local derp = client:new("Fretabladid", "http://antsgame.azurewebsites.net")
-- local derp = client:new("Fretabladid", "http://localhost:16901")
derp:start()
