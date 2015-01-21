local http = require("libs/socket.http")
local json = require("dkjson")
local ltn12 = require("libs/ltn12")
local ffi = require("ffi")

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

-- for converting x/y pair to cell id's
local function convertToId(x, y, width)
    return y*width+x + 1
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

local function boardIndex(x, y, width)
    return (y-1)*width+x
end

local cell = class()
function cell:__init()
    self.type = nil
    self.neighbors = {}
    self.Id = nil
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
            self.cells[i][j] = cell:new()
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
        error("OH MAN, you tried updating a position of something that wasn't an ant...")
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

function client:updateBoard(gameState)
    -- HOME (may not be fully accurate as ants do spawn atop it)
    local myHill = gameState.Hill
    self.board.cells[myHill.X+1][myHill.Y+1].type = "myHill"

    -- will store a wall exists
    for i = 1, #gameState.Walls do
        local currentWall = gameState.Walls[i]
        self.board.cells[currentWall.X+1][currentWall.Y+1].type = "wall"
    end

    -- will store my ants
    for i = 1, #gameState.FriendlyAnts do
        local currentAnt = gameState.FriendlyAnts[i]
        self.board.cells[currentAnt.X+1][currentAnt.Y+1].type = "ant"
        self.board.cells[currentAnt.X+1][currentAnt.Y+1].Id = currentAnt.Id
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

end

function client:update(gameState)

    -- OH BOY
    if self.board == nil then
        print(gameState.Width)
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

    local random = {"up", "down", "left", "right"}

    for i = 1, #gameState.FriendlyAnts do
        local currentAnt = gameState.FriendlyAnts[i]
        local crazyRandom
        local future
        repeat
            crazyRandom = random[math.random(4)]
            future = self.board:checkFutureType(currentAnt.X+1, currentAnt.Y+1, crazyRandom)
            print(future)
        until future ~= "ant" and future ~= "wall"
        self.board:updateAntPosition(currentAnt.X+1, currentAnt.Y+1, crazyRandom)
        self.pendingMoves [ i ] = {antId = currentAnt.Id, direction = crazyRandom}
    end

    self.board:clear()

end

function client:sendUpdate()
    local update = { AuthToken = self.AuthToken, GameId = self.GameId, MoveAntRequests = self.pendingMoves }
    local response = httpRequest(self.url .. "/api/game/update", "POST", self.headers, update)
    --print("Moves Successful:", response.Success)
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
