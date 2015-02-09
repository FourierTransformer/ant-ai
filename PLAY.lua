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
    self.directions = {"left", "right", "up", "down"}
    self.explorers = 0
    self.attackers = 0
    self.gatherers = 0
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

function client:inputGeneric(gameState)

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
    if gameState.EnemyHills and gameState.EnemyHills[1] then
        for i= 1, #gameState.EnemyHills do
            local currentHill = gameState.EnemyHills[i]
            self.board.cells[currentHill.X+1][currentHill.Y+1].type = "enemyHill"
            self.enemyHill[i] = enemyHill:new(currentHill.X+1, currentHill.Y+1)
        end
    end

end

function client:setupAnts(FriendlyAnts, Width, Height, Fog)
    -- Gotta clear this up real quick for our count
    self.explorers = 0
    self.attackers = 0
    self.gatherers = 0

    -- GO through and create/update a bunch of ants
    for k = 1, #FriendlyAnts do

        -- VARS on VARS YO
        local currentBoardAnt = FriendlyAnts[k]
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
                self.gatherers = self.gatherers + 1
            elseif currentAnt.status == "oneAway" then
                currentAnt.status = nil
            elseif currentAnt.status == "explore" then
                if currentAnt.x == currentAnt.destinationX and currentAnt.y == currentAnt.destinationY then
                    currentAnt.status = nil
                end
                self.explorers = self.explorers + 1
            elseif currentAnt.status == "attack" then
                self.attackers = self.attackers + 1
            end

        -- the ant doesn't exist
        else
            --create it and set it as the current ant
            self.ants[currentAntId] = ant:new(currentBoardAnt.X+1, currentBoardAnt.Y+1)
            currentAnt = self.ants[currentAntId]
        end

        -- update the board
        self.board.cells[currentAnt.x][currentAnt.y].type = "ant"

        -- determine approachability
        for j = Fog, 0, -1 do
            for i = -(Fog-j), Fog-j do
                local x = (currentAnt.x+i)
                x = x % Width + 1
                local y = (currentAnt.y+j)
                y = y % Height + 1
                self.board.cells[x][y].approachability = self.board.cells[x][y].approachability - 1
            end
        end

        -- poor man's BFS (bottom)
        for j = -Fog, -1, 1 do
            for i = -(Fog+j), Fog+j do
                local x = (currentAnt.x+i)
                x = x % Width + 1
                local y = (currentAnt.y+j)
                y = y % Height + 1
                self.board.cells[x][y].approachability = self.board.cells[x][y].approachability - 1
            end
        end
    end
end

function client:defense(myHill, FriendlyAnts)
-- (for now: .25 of the ants will ant dance around the base)
    local antsToDance = math.ceil(.3 * #FriendlyAnts)
    print("Defenders: ", antsToDance)
    local area = antsToDance
    local smallestAnts = Heap()
    local currentlyDancing = 0
    for j, ant in pairs(self.ants) do
        if ant.status == "DANCE" then
            currentlyDancing = currentlyDancing + 1
        elseif ant.status == "goHome" then
            currentlyDancing = currentlyDancing + 1
            if self.board:dist2(ant.x, ant.y, myHill.X+1, myHill.Y+1) <= area then
                ant.status = "DANCE"
                ant.destinationX = myHill.X+1
                ant.destinationY = myHill.Y+1
            end
        elseif ant.status == nil then
            smallestAnts:push(ant, self.board:dist2(ant.x, ant.y, myHill.X+1, myHill.Y+1))
        end
    end

    -- pop off the nearest quarter and let them DANCE
    antsToDance = antsToDance - currentlyDancing
    if antsToDance > 0 then
        local thriller
        for i = 1, antsToDance do
            if not smallestAnts:isEmpty() then
                thriller = smallestAnts:pop()
                thriller.status = "DANCE"
                if self.board:dist2(thriller.x, thriller.y, myHill.X+1, myHill.Y+1) > area then
                    thriller.status = "goHome"
                    thriller.destinationX = myHill.X+1
                    thriller.destinationY = myHill.Y+1
                end
            end
        end

    -- SO, we're losing ants...
    elseif antsToDance < 0 then
        local stopDancing = math.abs(antsToDance)
        for j, ant in pairs(self.ants) do
            if stopDancing > 0 and ant.status == "goHome" then
                ant.status = nil
                stopDancing = stopDancing - 1
            end
        end
        for j, ant in pairs(self.ants) do
            if stopDancing > 0 and ant.status == "DANCE" then
                ant.status = nil
                stopDancing = stopDancing - 1
            end
        end
    end
end

function client:guessEnemy(EnemyAnts, myHill, fog)
    -- for each ant, find the nearest food and assume it's heading in that direction
    for j = 1, #EnemyAnts do
        local ant = EnemyAnts[j]
        local shortestDistance = math.huge
        local nearestFoodNum = nil
        for i = 1, #self.food do
            local antDist = self.board:dist2(ant.X+1, ant.Y+1, self.food[i].x, self.food[i].y)
            if antDist < shortestDistance then
                shortestDistance = antDist
                nearestFoodNum = i
            end
        end
        if shortestDistance ~= math.huge then
            local path = self.board:aStar(ant.X+1, ant.Y+1, self.food[nearestFoodNum].x, self.food[nearestFoodNum].y, "enemy")
            if path ~= nil and path[1] ~= nil then
                self.board:updateEnemyPosition(ant.X+1, ant.Y+1, path[1])
            end
        end
    end

    -- if an enemy ant has cleared the fog. Get ready. it's game time.
    for i = 1, #EnemyAnts do
        local ant = EnemyAnts[i]
        if self.board:dist2(ant.X+1, ant.Y+1, myHill.X+1, myHill.Y+1) < fog then
            local path = self.board:aStar(ant.X+1, ant.Y+1, myHill.X+1, myHill.Y+1, "enemy")
            if path ~= nil and path[1] ~= nil then
                self.board:updateEnemyPosition(ant.X+1, ant.Y+1, path[1])
            end 
        end
    end
end

function client:oneOff(ants)
    for i = 1, #ants do
        local currentId = ants[i].Id
        local ant = self.ants[currentId]
        if ant.status == nil or ant.status == "gather" or ant.status == "explore" or ant.status == "goHome" then
            local direction, worthIt = self.board:findFirstAvailable(ant.x, ant.y, 1)
            -- worthIt returns true if futureEnemy or food is one away
            if worthIt then
                ant.status = "oneAway"
                self.board:updateAntPosition(ant.x, ant.y, direction)
                self.pendingMoves [ #self.pendingMoves+1 ] = {antId = currentId, direction = self.directions[direction]}
            end
        end
    end
end

function client:explore(FriendlyAnts, Fog)
    -- HOW MANY EXPLORERS?!?!?
    local antExplorers = math.floor(.2 * #FriendlyAnts)
    print("Explorers: ", antExplorers)
    
    -- figure out how many ants we have explorin'
    antExplorers = antExplorers - self.explorers

    -- SEND 'EM OUT!
    if antExplorers > 0 then

        -- FIND OUT WHERE WE NEED TO GO!
        local approachability = Heap:new()
        for i = 1, self.board.width do
            for j = 1, self.board.height do
                local cell = self.board.cells[i][j]
                approachability:push(cell, -cell.approachability)
            end
        end

        -- send some ants there!
        for i = #FriendlyAnts, 1, -1 do
            local currentAnt = self.ants[FriendlyAnts[i].Id]
            if antExplorers > 0 and currentAnt.status == nil then
                local cellToGoTo = approachability:pop()
                currentAnt.status = "explore"
                currentAnt.destinationX = cellToGoTo.x
                currentAnt.destinationY = cellToGoTo.y
                antExplorers = antExplorers - 1
            end
        end

    -- OH NOES we gotta clear up some ant explorers (aka RETREAT... oh boy)
    else

        for i = 1, #FriendlyAnts do
            local currentAnt = self.ants[FriendlyAnts[i].Id]
            if antExplorers < 0 and currentAnt.status == "explore" then
                currentAnt.status = nil
                currentAnt.destinationX = nil
                currentAnt.destinationY = nil
                antExplorers = antExplorers + 1
            end
        end        

    end
end

-- Sends the nearest FREE ant to the enemy hill
function client:attack(FriendlyAnts)
    -- HOW MANY EXPLORERS?!?!?
    local antAttackers = math.ceil(.1 * #FriendlyAnts)
    print("Attackers: ", antAttackers)

    -- figure out how many to send out
    antAttackers = antAttackers - self.attackers

    -- SEND SOME OUT
    if antAttackers > 0 then
        for i = 1, antAttackers do
            -- head for the enemy hill!
            for i = 1, #self.enemyHill do
                local shortestDistance = math.huge
                local nearestAnt = nil
                for j, ant in pairs(self.ants) do
                    -- only send a free ant
                    if ant.status == nil then
                        local antDist = self.board:dist2(ant.x, ant.y, self.enemyHill[i].x, self.enemyHill[i].y)
                        if antDist < shortestDistance then
                            shortestDistance = antDist
                            nearestAnt = ant
                        end
                    end
                end
                if shortestDistance ~= math.huge then
                    -- self.board.cells[foodX][foodY].type = "finalDestination"
                    nearestAnt.status = "attack"
                    nearestAnt.destinationX = self.enemyHill[i].x
                    nearestAnt.destinationY = self.enemyHill[i].y
                end
            end
        end
    end
end

function client:collectFood()
    -- collect all the nearest food.
    for i = 1, #self.food do
        local shortestDistance = math.huge
        local nearestAnt = nil
        for j, ant in pairs(self.ants) do
            if ant.status == nil then
                local antDist = self.board:dist2(ant.x, ant.y, self.food[i].x, self.food[i].y)
                if antDist < shortestDistance then
                    shortestDistance = antDist
                    nearestAnt = ant
                end
            end
        end
        if shortestDistance ~= math.huge then
            -- self.board.cells[foodX][foodY].type = "finalDestination"
            nearestAnt.status = "gather"
            nearestAnt.destinationX = self.food[i].x
            nearestAnt.destinationY = self.food[i].y
        end
    end
end

function client:print(Height, Width)
    for j = 1, Height do
        local herp = ""
        for i = 1, Width do
            local currentCell = self.board.cells[i][j]
            if currentCell.type == "ant" then
                herp = herp .. "A "
            elseif currentCell.type == "enemy" then
                herp = herp .. "E "
            elseif currentCell.type == "futureEnemy" then
                herp = herp .. "F "
            else
                herp = herp .. self.board.cells[i][j].approachability .. " "
            end
        end
        print(herp)
    end
end

function client:updateAnts(gameState)

    -- do all the boring stuffs
    self:inputGeneric(gameState)

    -- ANTS ANTS ANTS
    self:setupAnts(gameState.FriendlyAnts, gameState.Width, gameState.Height, gameState.FogOfWar)

    -- setup a defense of 25% ants
    self:defense(gameState.Hill, gameState.FriendlyAnts)

    -- guess where the enemy is going
    self:guessEnemy(gameState.EnemyAnts, gameState.Hill, gameState.FogOfWar)

    -- handle things that are one square off
    self:oneOff(gameState.FriendlyAnts)

    -- EXPLORE THE SPACE YO
    self:explore(gameState.FriendlyAnts)

    -- send 10% to their doom (if we can see it)
    if gameState.EnemyHills and gameState.EnemyHills[1] then
        self:attack(gameState.FriendlyAnts)
    end

    -- collect all them foods
    self:collectFood()

    -- FRENZY MODE. FUN STUFFS
    -- if #gameState.FriendlyAnts > 20 then
    --     for i= 1, #gameState.EnemyHills do
    --         local currentHill = gameState.EnemyHills[i]
    --         self.board.cells[currentHill.X+1][currentHill.Y+1].type = "enemyHill"
    --         for k = 1, #gameState.FriendlyAnts do
    --             local currentAnt = gameState.FriendlyAnts[k]
    --             if self.ants[currentAnt.Id].status ~= "DANCE" then
    --                 self.ants[currentAnt.Id].status = "attack"
    --                 self.ants[currentAnt.Id].destinationX = currentHill.X+1
    --                 self.ants[currentAnt.Id].destinationY = currentHill.Y+1
    --             end
    --         end
    --     end
    -- end

    -- print it out! (aka debuggs)
    -- self:print(gameState.Height, gameState.Width)
end

function client:update(gameState)

    -- OH BOY
    if self.board == nil then
        self.board = board:new(gameState.Width, gameState.Height)
    end

    -- LAGS BRO
    self:getTurnInfo()

    -- create a distribution of places that need to be visited
    for i = 1, gameState.Width do
        for j = 1, gameState.Height do
            self.board.cells[i][j].approachability = self.board.cells[i][j].approachability + 1
        end
    end

    -- figure out that hive mind map!
    self:updateAnts(gameState)

    -- update turn info
    self:getTurnInfo()

    -- handle all the moves
    for i = 1, #gameState.FriendlyAnts do
        local currentId = gameState.FriendlyAnts[i].Id
        local currentAnt = self.ants[currentId]
        local futureDirection

        if currentAnt.status == nil or currentAnt.status == "DANCE" then
            local firstFree = self.board:findFirstAvailable(currentAnt.x, currentAnt.y, math.random(4))
            futureDirection = firstFree
        elseif  currentAnt.status == "gather" or currentAnt.status == "goHome" or 
                currentAnt.status == "attack" or currentAnt.status == "explore" then
            local path = self.board:aStar(currentAnt.x, currentAnt.y, currentAnt.destinationX, currentAnt.destinationY, "ant")

            if path == nil or path[1] == nil then 
                currentAnt.status = nil 
                currentAnt.destinationX = nil
                currentAnt.destinationY = nil
                futureDirection = self.board:findFirstAvailable(currentAnt.x, currentAnt.y, math.random(4))
            else
                futureDirection = path[1]
            end
        end

        if futureDirection ~= nil then
            self.board:updateAntPosition(currentAnt.x, currentAnt.y, futureDirection)
            self.pendingMoves [ #self.pendingMoves+1 ] = {antId = currentId, direction = self.directions[futureDirection]}
        end

    end

    -- update turn info
    self:getTurnInfo()

    -- clear board!
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

local derp = client:new("GAZORPAZORP", "http://antsgame.azurewebsites.net")
-- local derp = client:new("Fretabladid", "http://localhost:16901")
derp:start()
