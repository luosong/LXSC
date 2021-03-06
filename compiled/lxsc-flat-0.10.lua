local LXSC = {
	VERSION="0.10",
	scxmlNS="http://www.w3.org/2005/07/scxml"
}

-- Horribly simple xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
function LXSC.uuid4()
	return table.concat({
		string.format('%04x', math.random(0, 0xffff))..string.format('%04x',math.random(0, 0xffff)),
		string.format('%04x', math.random(0, 0xffff)),
		string.format('4%03x',math.random(0, 0xfff)),
		string.format('a%03x',math.random(0, 0xfff)),
		string.format('%06x', math.random(0, 0xffffff))..string.format('%06x',math.random(0, 0xffffff))
	},'-')
end

LXSC.State={}; LXSC.State.__meta = {__index=LXSC.State}

LXSC.State.stateKinds = {state=1,parallel=1,final=1,history=1,initial=1}
LXSC.State.realKinds  = {state=1,parallel=1,final=1}
LXSC.State.aggregates = {onentry=1,onexit=1,datamodel=1,donedata=1}

function LXSC:state(kind)
	local t = {
		_kind       = kind or 'state',
		id          = kind.."-"..self.uuid4(),
		isAtomic    = true,
		isCompound  = false,
		isParallel  = kind=='parallel',
		isHistory   = kind=='history',
		isFinal     = kind=='final',
		ancestors   = {},

		states      = {},
		reals       = {},
		transitions = {},
		_eventlessTransitions = {},
		_eventedTransitions   = {},

		_onentrys   = {},
		_onexits    = {},
		_datamodels = {},
		_donedatas  = {},
		_invokes    = {}
	}
	t.selfAndAncestors={t}
	return setmetatable(t,self.State.__meta)
end

function LXSC.State:attr(name,value)
	if name=="name" or name=="id" or name=="initial" then
		self[name] = value
	else
		if self[name] then print(string.format("Warning: updating state %s=%s with %s=%s",name,tostring(self[name]),name,tostring(value))) end
		self[name] = value
	end
end

function LXSC.State:addChild(item)
	if item._kind=='transition' then
		item.source = self
		table.insert( self.transitions, item )

	elseif self.aggregates[item._kind] then
		item.state = self

	elseif self.stateKinds[item._kind] then
		table.insert(self.states,item)
		item.parent = self
		item.ancestors[1] = self
		item.ancestors[self] = true
		item.selfAndAncestors[2] = self
		for i,anc in ipairs(self.ancestors) do
			item.ancestors[i+1]        = anc
			item.ancestors[anc]        = true
			item.selfAndAncestors[i+2] = anc
		end
		if self.realKinds[item._kind] then
			table.insert(self.reals,item)
			self.isCompound = self._kind~='parallel'
			self.isAtomic   = false
		end

	elseif item._kind=='invoke' then
		item.state = self
		table.insert(self._invokes,item)

	-- else print("Warning: unhandled child of state: "..item._kind )
	end
end

function LXSC.State:ancestorsUntil(stopNode)
	local i=0
	return function()
		i=i+1
		if self.ancestors[i] ~= stopNode then
			return self.ancestors[i]
		end
	end
end

function LXSC.State:createInitialTo(stateOrId)
	local initial = LXSC:state('initial')
	self:addChild(initial)
	local transition = LXSC:transition()
	initial:addChild(transition)
	transition:addTarget(stateOrId)
	self.initial = initial
end

function LXSC.State:convertInitials()
	if type(self.initial)=='string' then
		-- Convert initial="..." attribute to <initial> state
		self:createInitialTo(self.initial)
	elseif not self.initial then
		local initialElement
		for _,s in ipairs(self.states) do
			if s._kind=='initial' then initialElement=s; break end
		end

		if initialElement then
			self.initial = initialElement
		elseif self.states[1] then
			self:createInitialTo(self.states[1])
		end
	end
	for _,s in ipairs(self.reals) do s:convertInitials() end
end

function LXSC.State:cacheReference(lookup)
	lookup[self.id] = self
	for _,s in ipairs(self.states) do s:cacheReference(lookup) end
end

function LXSC.State:resolveReferences(lookup)
	for _,t in ipairs(self.transitions) do
		if t.targets then
			for i,target in ipairs(t.targets) do
				if type(target)=="string" then
					if lookup[target] then
						t.targets[i] = lookup[target]
					else
						error(string.format("Cannot find start with id '%s' for target",tostring(target)))
					end
				end
			end
		end
	end
	for _,s in ipairs(self.states) do s:resolveReferences(lookup) end
end

function LXSC.State:descendantOf(possibleAncestor)
	return self.ancestors[possibleAncestor]
end

-- ********************************************************

-- These elements pass their children through to the appropriate collection on the state
for kind,collection in pairs{ datamodel='_datamodels', donedata='_donedatas', onentry='_onentrys', onexit='_onexits' } do
	LXSC[kind] = function()
		local t = {_kind=kind}
		function t:addChild(item) table.insert(self.state[collection],item) end
		return t
	end
end
LXSC.SCXML={}; LXSC.SCXML.__meta = {__index=LXSC.SCXML}
setmetatable(LXSC.SCXML,{__index=LXSC.State})

function LXSC:scxml()
	local t = LXSC:state('scxml')
	t.name      = "(lxsc)"
	t.binding   = "early"
	t.datamodel = "lua"
	t.id        = nil

	t.running   = false
	t._config   = LXSC.OrderedSet()

	return setmetatable(t,LXSC.SCXML.__meta)
end

-- Fetch a single named value from the data model
function LXSC.SCXML:get(location)
	return self._data:get(location)
end

-- Set a single named value in the data model
function LXSC.SCXML:set(location,value)
	self._data:set(location,value)
end

-- Evaluate a single Lua expression and return the value
function LXSC.SCXML:eval(expression)
	return self._data:eval(expression)
end

-- Run arbitrary script code (multiple lines) with no return value
function LXSC.SCXML:run(code)
	self._data:run(code)
end

function LXSC.SCXML:isActive(stateId)
	if not self._stateById then self:expandScxmlSource() end
	return self._config[self._stateById[stateId]]
end

function LXSC.SCXML:activeStateIds()
	local a = LXSC.OrderedSet()
	for _,s in ipairs(self._config) do a:add(s.id) end
	return a
end

function LXSC.SCXML:activeAtomicIds()
	local a = LXSC.OrderedSet()
	for _,s in ipairs(self._config) do
		if s.isAtomic then a:add(s.id) end
	end
	return a
end

function LXSC.SCXML:allEvents()
	local all = {}
	local function crawl(state)
		for _,s in ipairs(state.states) do
			for _,t in ipairs(s._eventedTransitions) do
				for _,e in ipairs(t.events) do
					all[e.name] = true
				end
			end
			crawl(s)
		end
	end
	crawl(self)
	return all
end

function LXSC.SCXML:availableEvents()
	local all = {}
	for _,s in ipairs(self._config) do
		for _,t in ipairs(s._eventedTransitions) do
			for _,e in ipairs(t.events) do
				all[e.name] = true
			end
		end
	end
	return all
end

function LXSC.SCXML:allStateIds()
	if not self._stateById then self:expandScxmlSource() end
	local stateById = {}
	for id,s in pairs(self._stateById) do
		if s._kind~="initial" then stateById[id]=s end
	end
	return stateById
end

function LXSC.SCXML:atomicStateIds()
	if not self._stateById then self:expandScxmlSource() end
	local stateById = {}
	for id,s in pairs(self._stateById) do
		if s.isAtomic and s._kind~="initial" then stateById[id]=s end
	end
	return stateById
end

function LXSC.SCXML:addChild(item)
	if item._kind=='script' then
		self._script = item
	else
		LXSC.State.addChild(self,item)
	end
end
LXSC.Transition={}; LXSC.Transition.__meta = {__index=LXSC.Transition}

function LXSC:transition()
	local t = { _kind='transition', _exec={}, type="external" }
	setmetatable(t,self.Transition.__meta)
	return t
end

function LXSC.Transition:attr(name,value)
	if name=='event' then
		self.events = {}
		self._event = value
		for event in string.gmatch(value,'[^%s]+') do
			local tokens = {}
			for token in string.gmatch(event,'[^.*]+') do table.insert(tokens,token) end
			tokens.name = table.concat(tokens,'.')
			table.insert(self.events,tokens)
		end

	elseif name=='target' then
		self.targets = nil
		self._target = value
		for target in string.gmatch(value,'[^%s]+') do self:addTarget(target) end

	elseif name=='cond' or name=='type' then
		self[name] = value

	else
		if self[name] then print(string.format("Warning: updating transition %s=%s with %s=%s",name,tostring(self[name]),name,tostring(value))) end
		self[name] = value

	end
end

function LXSC.Transition:addChild(item)
	table.insert(self._exec,item)
end

function LXSC.Transition:addTarget(stateOrId)
	if not self.targets then self.targets = LXSC.List() end
	table.insert(self.targets,stateOrId)
end

function LXSC.Transition:conditionMatched(datamodel)
	return not self.cond or datamodel:eval(self.cond)
end

function LXSC.Transition:matchesEvent(event)
	for _,tokens in ipairs(self.events) do
		if event.name==tokens.name or tokens.name=="*" then
			return true
		elseif #tokens <= #event._tokens then
			local matched = true
			for i,token in ipairs(tokens) do
				if event._tokens[i]~=token then
					matched = false
					break
				end
			end
			if matched then
				-- print("Transition",self._event,"matched",event.name)
				return true
			end
		end
	end
	-- print("Transition",self._event,"does not match",event.name)
end

function LXSC.Transition:inspect()
	return string.format(
		"<transition in '%s'%s%s%s>",
		self.source.id or self.source.name,
		self._event and (" on '"..self._event.."'") or "",
		self.cond and (" if '"..self.cond.."'") or "",
		self._target and (" to '"..self._target.."'") or ""
	)
end
LXSC.Datamodel = {}; LXSC.Datamodel.__meta = {__index=LXSC.Datamodel}

setmetatable(LXSC.Datamodel,{__call=function(dm,scxml,scope)
	if not scope then scope = {} end
	function scope.In(id) return scxml:isActive(id) end
	return setmetatable({ statesInited={}, scxml=scxml, scope=scope, cache={} },dm.__meta)
end})

function LXSC.Datamodel:initAll()
	local function recurse(state)
		self:initState(state)
		for _,s in ipairs(state.reals) do recurse(s) end
	end
	recurse(self.scxml)
end

function LXSC.Datamodel:initState(state)
	if not self.statesInited[state] then
		for _,data in ipairs(state._datamodels) do
			-- TODO: support data.src
			self:set( data.id, self:eval(data.expr or tostring(data._text)) )
		end
		self.statesInited[state] = true
	end
end

function LXSC.Datamodel:eval(expression)
	return self:run('return '..expression)
end

function LXSC.Datamodel:run(code)
	local func,message = self.cache[code]
	if not func then
		func,message = loadstring(code)
		if func then
			self.cache[code] = func
			setfenv(func,self.scope)
		else
			self.scxml:fireEvent("error.execution.syntax",message,true)
		end
	end
	if func then
		local ok,result = pcall(func)
		if not ok then
			self.scxml:fireEvent("error.execution.evaluation",result,true)
		else
			return result
		end
	end
end

function LXSC.Datamodel:set(location,value)
	-- TODO: support foo.bar location dereferencing
	if location~=nil then
		self.scope[location] = value
		if self.scxml.onDataSet then self.scxml.onDataSet(location,value) end
	else
		self.scxml:fireEvent("error.execution.invalid-set",true)
	end
end

function LXSC.Datamodel:get(id)
	return self.scope[id]
end

local function triggersDescriptor(self,descriptor)
	if self.name==descriptor or descriptor=="*" then
		return true
	else
		local i=1
		for token in string.gmatch(descriptor,'[^.*]+') do
			if self._tokens[i]~=token then return false end
			i=i+1
		end
		return true
	end
	return false
end

local function triggersTransition(self,t)
	return t:matchesEvent(self)
end

LXSC.Event = function(name,data)
	local e = {name=name,data=data,_tokens={},triggersDescriptor=triggersDescriptor,triggersTransition=triggersTransition}
	for token in string.gmatch(name,'[^.*]+') do table.insert(e._tokens,token) end
	return e
end
local generic = {}
local genericMeta = {__index=generic }

function LXSC:_generic(kind,nsURI)
	return setmetatable({_kind=kind,_kids={},_nsURI=nsURI},genericMeta)
end

function generic:addChild(item)
	table.insert(self._kids,item)
end

function generic:attr(name,value)
	self[name] = value
end

setmetatable(LXSC,{__index=function() return LXSC._generic end})
LXSC.Exec = {}

function LXSC.Exec:log(scxml)
	local message = {self.label}
	if self.expr then table.insert(message,scxml:eval(self.expr)) end
	print(table.concat(message,": "))
end

function LXSC.Exec:assign(scxml)
	-- TODO: support child executable content in place of expr
	scxml:set( self.location, scxml:eval(self.expr) )
end

function LXSC.Exec:raise(scxml)
	scxml:fireEvent(self.event,nil,true)
end

function LXSC.Exec:script(scxml)
	scxml:run(self._text)
end

function LXSC.Exec:send(scxml)
	-- TODO: support type/typeexpr/target/targetexpr
	local name = self.event or scxml:eval(self.eventexpr)
	local data
	if self.namelist then
		data = {}
		for name in string.gmatch(self.namelist,'[^%s]+') do data[name] = scxml:get(name) end
	end
	if self.idlocation and not self.id then scxml:set( scxml:eval(self.idlocation), LXSC.uuid4() ) end

	if self.delay or self.delayexpr then
		local delay = self.delay or scxml:eval(self.delayexpr)
		local delaySeconds, units = string.match(delay,'^(.-)(m?s)')
		delaySeconds = tonumber(delaySeconds)
		if units=="ms" then delaySeconds = delaySeconds/1000 end
		local delayedEvent = { expires=os.clock()+delaySeconds, name=name, data=data, id=self.id }
		local i=1
		for _,delayed2 in ipairs(scxml._delayedSend) do
			if delayed2.expires>delayedEvent.expires then break else i=i+1 end
		end
		table.insert(scxml._delayedSend,i,delayedEvent)
	else
		scxml:fireEvent(name,data,false)
	end
end

function LXSC.Exec:cancel(scxml)
	scxml:cancelDelayedSend(self.sendid or scxml:eval(self.sendidexpr))
end

function LXSC.SCXML:processDelayedSends() -- automatically called by :step()
	local i,last=1,#self._delayedSend
	while i<=last do
		local delayedEvent = self._delayedSend[i]
		if delayedEvent.expires <= os.clock() then
			table.remove(self._delayedSend,i)
			self:fireEvent(delayedEvent.name,delayedEvent.data,false)
			last = last-1
		else
			i=i+1
		end
	end
end

function LXSC.SCXML:cancelDelayedSend(sendId)
	for i=#self._delayedSend,1,-1 do
		if self._delayedSend[i].id==sendId then table.remove(self._delayedSend,i) end
	end
end

-- ******************************************************************

function LXSC.SCXML:executeContent(item)
	local handler = LXSC.Exec[item._kind]
	if handler then
		handler(item,self)
	else
		self:fireEvent('error.execution.unhandled',"unhandled executable type "..item._kind,true)
	end
end

LXSC.OrderedSet = {}; LXSC.OrderedSet.__meta = {__index=LXSC.OrderedSet}

setmetatable(LXSC.OrderedSet,{__call=function(o)
	return setmetatable({},o.__meta)
end})

function LXSC.OrderedSet:add(e)
	if not self[e] then
		local idx = #self+1
		self[idx] = e
		self[e] = idx
	end
end

function LXSC.OrderedSet:delete(e)
	local index = self[e]
	if index then
		table.remove(self,index)
		self[e] = nil
		for i,o in ipairs(self) do self[o]=i end -- Store new indexes
	end
end

function LXSC.OrderedSet:member(e)
	return self[e]
end

function LXSC.OrderedSet:isEmpty()
	return not self[1]
end

function LXSC.OrderedSet:clear()
	for k,v in pairs(self) do self[k]=nil end
end

function LXSC.OrderedSet:toList()
	return LXSC.List(unpack(self))
end

-- *******************************************************************

LXSC.List = {}; LXSC.List.__meta = {__index=LXSC.List}
setmetatable(LXSC.List,{__call=function(o,...)
	local l = {...}
	setmetatable(l,o.__meta)
	return l
end})

function LXSC.List:head()
	return self[1]
end

function LXSC.List:tail()
	local l = LXSC.List(unpack(self))
	table.remove(l,1)
	return l
end

function LXSC.List:append(...)
	local len=#self
	for i,v in ipairs{...} do self[len+i] = v end
	return self
end

function LXSC.List:filter(f)
	local t={}
	local i=1
	for _,v in ipairs(self) do
		if f(v) then
			t[i]=v; i=i+1
		end
	end
	return LXSC.List(unpack(t))
end

function LXSC.List:some(f)
	for _,v in ipairs(self) do
		if f(v) then return true end
	end
end

function LXSC.List:every(f)
	for _,v in ipairs(self) do
		if not f(v) then return false end
	end
	return true
end

function LXSC.List:sort(f)
	table.sort(self,f)
	return self
end

-- *******************************************************************

LXSC.Queue = {}; LXSC.Queue.__meta = {__index=LXSC.Queue}
setmetatable(LXSC.Queue,{__call=function(o)
	local q = {}
	setmetatable(q,o.__meta)
	return q
end})

function LXSC.Queue:enqueue(e)
	self[#self+1] = e
end

function LXSC.Queue:dequeue()
	return table.remove(self,1)
end

function LXSC.Queue:isEmpty()
	return not self[1]
end
(function(S)
S.MAX_ITERATIONS = 1000
local OrderedSet,Queue = LXSC.OrderedSet, LXSC.Queue

-- ****************************************************************************

local function documentOrder(a,b) return a._order < b._order end
local function exitOrder(a,b)     return b._order < a._order end
local function isAtomicState(s)   return s.isAtomic          end
local function findLCPA(first,rest) -- least common parallel ancestor
	for _,anc in ipairs(first.ancestors) do
		if anc._kind=='parallel' then
			if rest:every(function(s) return s:descendantOf(anc) end) then
				return anc
			end
		end
	end
end
local function findLCCA(first,rest) -- least common compound ancestor
	for _,anc in ipairs(first.ancestors) do
		if anc.isCompound then
			if rest:every(function(s) return s:descendantOf(anc) end) then
				return anc
			end
		end
	end
end

-- ****************************************************************************

function S:interpret(options)
	-- if not self:validate() then self:failWithError() end
	if not self._stateById then self:expandScxmlSource() end
	self._config:clear()
	self._delayedSend = {}
	-- self.statesToInvoke = OrderedSet()
	self._data = LXSC.Datamodel(self,options and options.data)
	self.historyValue   = {}

	self._internalQueue = Queue()
	self._externalQueue = Queue()
	self.running = true
	if self.binding == "early" then self._data:initAll() end
	if self._script then self:executeContent(self._script) end
	self:enterStates(self.initial.transitions)
	self:mainEventLoop()
end

-- ******************************************************************************************************
-- ******************************************************************************************************
-- ******************************************************************************************************

function S:mainEventLoop()
	local anyChange, enabledTransitions, stable, iterations
	while self.running do
		anyChange = false
		stable = false
		iterations = 0
		while self.running and not stable and iterations<self.MAX_ITERATIONS do
			enabledTransitions = self:selectEventlessTransitions()
			if enabledTransitions:isEmpty() then
				if self._internalQueue:isEmpty() then
					stable = true
				else
					local internalEvent = self._internalQueue:dequeue()
					self._data:set("_event",internalEvent)
					enabledTransitions = self:selectTransitions(internalEvent)
				end
			end
			if not enabledTransitions:isEmpty() then
				anyChange = true
				self:microstep(enabledTransitions)
			end
			iterations = iterations + 1
		end

		if iterations>=S.MAX_ITERATIONS then print(string.format("Warning: stopped unstable system after %d internal iterations",S.MAX_ITERATIONS)) end

		-- for _,state in ipairs(self.statesToInvoke) do for _,inv in ipairs(state._invokes) do self:invoke(inv) end end
		-- self.statesToInvoke:clear()

		if self._internalQueue:isEmpty() then
			local externalEvent = self._externalQueue:dequeue()
			if externalEvent then
				anyChange = true
				if externalEvent.name=='quit.lxsc' then
					self.running = false
				else
					self._data:set("_event",externalEvent)
					-- for _,state in ipairs(self._config) do
					-- 	for _,inv in ipairs(state._invokes) do
					-- 		if inv.invokeid == externalEvent.invokeid then self:applyFinalize(inv, externalEvent) end
					-- 		if inv.autoforward then self:send(inv.id, externalEvent) end
					-- 	end
					-- end
					enabledTransitions = self:selectTransitions(externalEvent)
					if not enabledTransitions:isEmpty() then
						self:microstep(enabledTransitions)
					end
				end
			end
		end

		if not anyChange then break end
	end

	if not self.running then self:exitInterpreter() end
end

-- ******************************************************************************************************
-- ******************************************************************************************************
-- ******************************************************************************************************

function S:exitInterpreter()
	local statesToExit = self._config:toList():sort(documentOrder)
	for _,s in ipairs(statesToExit) do
		for _,content in ipairs(s._onexits) do self:executeContent(content) end
		-- for _,inv     in ipairs(s._invokes) do self:cancelInvoke(inv)       end
		-- self._config:delete(s)
		-- if self:isFinalState(s) and s.parent._kind=='scxml' then self:returnDoneEvent(self:donedata(s)) end
	end
end

function S:selectEventlessTransitions()
	local enabledTransitions = OrderedSet()
	local atomicStates = self._config:toList():filter(isAtomicState):sort(documentOrder)
	for _,state in ipairs(atomicStates) do
		self:addEventlessTransition(state,enabledTransitions)
	end
	return self:filterPreempted(enabledTransitions)
end
-- TODO: store sets of evented vs. eventless transitions
function S:addEventlessTransition(state,enabledTransitions)
	for _,s in ipairs(state.selfAndAncestors) do
		for _,t in ipairs(s._eventlessTransitions) do
			if t:conditionMatched(self._data) then
				enabledTransitions:add(t)
				return
			end
		end
	end
end

function S:selectTransitions(event)
	local enabledTransitions = OrderedSet()
	local atomicStates = self._config:toList():filter(isAtomicState):sort(documentOrder)
	for _,state in ipairs(atomicStates) do
		self:addTransitionForEvent(state,event,enabledTransitions)
	end
	return self:filterPreempted(enabledTransitions)
end
-- TODO: store sets of evented vs. eventless transitions
function S:addTransitionForEvent(state,event,enabledTransitions)
	for _,s in ipairs(state.selfAndAncestors) do
		for _,t in ipairs(s._eventedTransitions) do
			if t:matchesEvent(event) and t:conditionMatched(self._data) then
				enabledTransitions:add(t)
				return
			end
		end
	end
end

function S:filterPreempted(enabledTransitions)
	local filteredTransitions = OrderedSet()
	for _,t1 in ipairs(enabledTransitions) do
		local anyPreemption = false
		for _,t2 in ipairs(filteredTransitions) do
			local t2Cat = self:preemptionCategory(t2)
			if t2Cat==3 or (t2Cat==2 and self:preemptionCategory(t1)==3) then
				anyPreemption = true
				break
			end
		end
		if not anyPreemption then filteredTransitions:add(t1) end
	end
	return filteredTransitions
end
function S:preemptionCategory(t)
	if not t.preemptionCategory then
		if not t.targets then
			t.preemptionCategory = 1
		elseif findLCPA( t.type=="internal" and t.source or t.source.parent, t.targets ) then
			t.preemptionCategory = 2
		else
			t.preemptionCategory = 3
		end
	end
	return t.preemptionCategory
end

function S:microstep(enabledTransitions)
	self:exitStates(enabledTransitions)
	for _,t in ipairs(enabledTransitions) do
		if self.onTransition then self.onTransition(t) end
		for _,executable in ipairs(t._exec) do self:executeContent(executable) end
	end
	self:enterStates(enabledTransitions)
	if self.onEnteredAll then self.onEnteredAll() end
end

function S:exitStates(enabledTransitions)
	local statesToExit = OrderedSet()
	for _,t in ipairs(enabledTransitions) do
		if t.targets then
			local ancestor
			if t.type == "internal" and t.source.isCompound and t.targets:every(function(s) return s:descendantOf(t.source) end) then
				ancestor = t.source
			else
				ancestor = findLCCA(t.source, t.targets)
			end
			for _,s in ipairs(self._config) do
				if s:descendantOf(ancestor) then statesToExit:add(s) end
			end
		end
	end

	-- for _,s in ipairs(statesToExit) do self.statesToInvoke:delete(s) end

	statesToExit = statesToExit:toList():sort(exitOrder)

	for _,s in ipairs(statesToExit) do
		-- TODO: create special history collection for speed
		for _,h in ipairs(s.states) do
			if h._kind=='history' then
				if self.historyValue[h.id] then
					self.historyValue[h.id]:clear()
				else
					self.historyValue[h.id] = OrderedSet()
				end
				for _,s0 in ipairs(self._config) do
					if h.type=='deep' then
						if s0.isAtomic and s0:descendantOf(s) then self.historyValue[h.id]:add(s0) end
					else
						if s0.parent==s then self.historyValue[h.id]:add(s0) end
					end
				end
			end
		end
	end

	for _,s in ipairs(statesToExit) do
		if self.onBeforeExit then self.onBeforeExit(s.id,s._kind,s.isAtomic) end
		for _,content in ipairs(s._onexits) do self:executeContent(content) end
		-- for _,inv in ipairs(s._invokes)     do self:cancelInvoke(inv) end
		self._config:delete(s)
	end
end

function S:enterStates(enabledTransitions)
	local statesToEnter = OrderedSet()
	local statesForDefaultEntry = OrderedSet()

	local function addStatesToEnter(state)	
		if state._kind=='history' then
			if self.historyValue[state.id] then
				for _,s in ipairs(self.historyValue[state.id]) do
					addStatesToEnter(s)
					for anc in s:ancestorsUntil(state.parent) do
						statesToEnter:add(anc)
					end
				end
			else
				for _,t in ipairs(state.transitions) do
					for _,s in ipairs(t.targets) do addStatesToEnter(s) end
				end
			end
		else
			statesToEnter:add(state)
			if state.isCompound then
				statesForDefaultEntry:add(state)
				for _,s in ipairs(state.initial.transitions[1].targets) do addStatesToEnter(s) end
			elseif state._kind=='parallel' then
				for _,s in ipairs(state.reals) do addStatesToEnter(s) end
			end
		end
	end

	for _,t in ipairs(enabledTransitions) do		
		if t.targets then
			local ancestor
			if t.type=="internal" and t.source.isCompound and t.targets:every(function(s) return s:descendantOf(t.source) end) then
				ancestor = t.source
			else
				ancestor = findLCCA(t.source, t.targets)
			end
			for _,s in ipairs(t.targets) do addStatesToEnter(s) end
			for _,s in ipairs(t.targets) do
				for anc in s:ancestorsUntil(ancestor) do
					statesToEnter:add(anc)
					if anc._kind=='parallel' then
						for _,child in ipairs(anc.reals) do
							local descendsFlag = false
							for _,s in ipairs(statesToEnter) do
								if s:descendantOf(child) then
									descendsFlag = true
									break
								end
							end
							if not descendsFlag then addStatesToEnter(child) end
						end
					end
				end
			end
		end
	end

	statesToEnter = statesToEnter:toList():sort(documentOrder)
	for _,s in ipairs(statesToEnter) do
		if s._kind=='scxml' then
			print("WARNING: tried to add scxml to the configuration!")
		else
			self._config:add(s)
			-- self.statesToInvoke:add(s)
			if self.binding=="late" then self._data:initState(s) end -- The datamodel ensures this happens only once per state
			for _,content in ipairs(s._onentrys) do self:executeContent(content) end
			if self.onAfterEnter then self.onAfterEnter(s.id,s._kind,s.isAtomic) end
			if statesForDefaultEntry:member(s) then
				for _,t in ipairs(s.initial.transitions) do
					for _,executable in ipairs(t._exec) do
						self:executeContent(executable)
					end
				end
			end
			if s._kind=='final' then
				local parent = s.parent
				if parent._kind=='scxml' then
					self.running = false
				else
					local grandparent = parent.parent
					self:fireEvent( "done.state."..parent.id, self:donedata(s), true )
					if grandparent and grandparent._kind=='parallel' then
						local allAreInFinal = true
						for _,child in ipairs(grandparent.reals) do
							if not self:isInFinalState(child) then
								allAreInFinal = false
								break
							end
						end
						if allAreInFinal then self:fireEvent( "done.state."..grandparent.id ) end
					end
				end
			end
		end
	end

	for _,s in ipairs(self._config) do
		if s._kind=='final' and s.parent._kind=='scxml' then self.running = false end
	end
end

function S:isInFinalState(s)
	if s.isCompound then
		for _,s in ipairs(s.reals) do
			if s._kind=='final' and self._config:member(s) then
				return true
			end
		end
	elseif s._kind=='parallel' then
		for _,s in ipairs(s.reals) do
			if not self:isInFinalState(s) then
				return false
			end
		end
		return true
	end
end

function S:expandScxmlSource()
	self:convertInitials()
	self._stateById = {}
	for _,s in ipairs(self.states) do s:cacheReference(self._stateById) end
	self:resolveReferences(self._stateById)
end


function S:donedata(state)
	local c = state._donedatas[1]
	if c then
		if c.kind=='content' then
			return c.expr and self._data:eval(c.expr) or c._text
		else
			local map = {}
			for _,p in ipairs(state._donedatas) do
				map[p.name] = self._data:eval(p.expr)
			end
			return map
		end
	end
end

function S:fireEvent(name,data,internalFlag)
	-- print("fireEvent(",name,data,internalFlag,")")
	local event = LXSC.Event(name,data)
	if self.onEventFired then self.onEventFired(event) end
	self[internalFlag and "_internalQueue" or "_externalQueue"]:enqueue(event)
	return event
end

-- Sensible aliases
S.start   = S.interpret
S.restart = S.interpret

function S:step()
	self:processDelayedSends()
	self:mainEventLoop()
end

end)(LXSC.SCXML)
local SLAXML = (function()
--[=====================================================================[
v0.5.1 Copyright © 2013 Gavin Kistner <!@phrogz.net>; MIT Licensed
See http://github.com/Phrogz/SLAXML for details.
--]=====================================================================]
local SLAXML = {
	VERSION = "0.5.1",
	_call = {
		pi = function(target,content)
			print(string.format("<?%s %s?>",target,content))
		end,
		comment = function(content)
			print(string.format("<!-- %s -->",content))
		end,
		startElement = function(name,nsURI)
			print(string.format("<%s%s>",name,nsURI and (" ("..nsURI..")") or ""))
		end,
		attribute = function(name,value,nsURI)
			print(string.format("  %s=%q%s",name,value,nsURI and (" ("..nsURI..")") or ""))
		end,
		text = function(text)
			print(string.format("  text: %q",text))
		end,
		closeElement = function(name,nsURI)
			print(string.format("</%s>",name))
		end,
	}
}

function SLAXML:parser(callbacks)
	return { _call=callbacks or self._call, parse=SLAXML.parse }
end

function SLAXML:parse(xml,options)
	if not options then options = { stripWhitespace=false } end

	-- Cache references for maximum speed
	local find, sub, gsub, char, push, pop = string.find, string.sub, string.gsub, string.char, table.insert, table.remove
	local first, last, match1, match2, match3, pos2, nsURI
	local pos = 1
	local state = "text"
	local textStart = 1
	local currentElement={}
	local currentAttributes={}
	local currentAttributeCt
	local nsStack = {}

	local entityMap  = { ["lt"]="<", ["gt"]=">", ["amp"]="&", ["quot"]='"', ["apos"]="'" }
	local entitySwap = function(orig,n,s) return entityMap[s] or n=="#" and char(s) or orig end
	local function unescape(str) return gsub( str, '(&(#?)([%d%a]+);)', entitySwap ) end

	local function finishText()
		if first>textStart and self._call.text then
			local text = sub(xml,textStart,first-1)
			if options.stripWhitespace then
				text = gsub(text,'^%s+','')
				text = gsub(text,'%s+$','')
				if #text==0 then text=nil end
			end
			if text then self._call.text(unescape(text)) end
		end
	end

	local function findPI()
		first, last, match1, match2 = find( xml, '^<%?([:%a_][:%w_.-]*) ?(.-)%?>', pos )
		if first then
			finishText()
			if self._call.pi then self._call.pi(match1,match2) end
			pos = last+1
			textStart = pos
			return true
		end
	end

	local function findComment()
		first, last, match1 = find( xml, '^<!%-%-(.-)%-%->', pos )
		if first then
			finishText()
			if self._call.comment then self._call.comment(match1) end
			pos = last+1
			textStart = pos
			return true
		end
	end

	local function nsForPrefix(prefix)
		for i=#nsStack,1,-1 do if nsStack[i][prefix] then return nsStack[i][prefix] end end
		error(("Cannot find namespace for prefix %s"):format(prefix))
	end

	local function startElement()
		first, last, match1 = find( xml, '^<([%a_][%w_.-]*)', pos )
		if first then
			currentElement[2] = nil
			finishText()
			pos = last+1
			first,last,match2 = find(xml, '^:([%a_][%w_.-]*)', pos )
			if first then
				currentElement[1] = match2
				currentElement[2] = nsForPrefix(match1)
				match1 = match2
				pos = last+1
			else
				currentElement[1] = match1
				for i=#nsStack,1,-1 do if nsStack[i]['!'] then currentElement[2] = nsStack[i]['!']; break end end
			end
			currentAttributeCt = 0
			push(nsStack,{})
			return true
		end
	end

	local function findAttribute()
		first, last, match1 = find( xml, '^%s+([:%a_][:%w_.-]*)%s*=%s*', pos )
		if first then
			pos2 = last+1
			first, last, match2 = find( xml, '^"([^<"]*)"', pos2 ) -- FIXME: disallow non-entity ampersands
			if first then
				pos = last+1
				match2 = unescape(match2)
			else
				first, last, match2 = find( xml, "^'([^<']*)'", pos2 ) -- FIXME: disallow non-entity ampersands
				if first then
					pos = last+1
					match2 = unescape(match2)
				end
			end
		end
		if match1 and match2 then
			local currentAttribute = {match1,match2}
			local prefix,name = string.match(match1,'^([^:]+):([^:]+)$')
			if prefix then
				if prefix=='xmlns' then
					nsStack[#nsStack][name] = match2
				else
					currentAttribute[1] = name
					currentAttribute[3] = nsForPrefix(prefix)
				end
			else
				if match1=='xmlns' then
					nsStack[#nsStack]['!'] = match2
					currentElement[2] = match2
				end
			end
			currentAttributeCt = currentAttributeCt + 1
			currentAttributes[currentAttributeCt] = currentAttribute
			return true
		end
	end

	local function findCDATA()
		first, last, match1 = find( xml, '^<!%[CDATA%[(.-)%]%]>', pos )
		if first then
			finishText()
			if self._call.text then self._call.text(match1) end
			pos = last+1
			textStart = pos
			return true
		end
	end

	local function closeElement()
		first, last, match1 = find( xml, '^%s*(/?)>', pos )
		if first then
			state = "text"
			pos = last+1
			textStart = pos

			if self._call.startElement then self._call.startElement(unpack(currentElement)) end
			if self._call.attribute then
			for i=1,currentAttributeCt do self._call.attribute(unpack(currentAttributes[i])) end end

			if match1=="/" then
				pop(nsStack)
				if self._call.closeElement then self._call.closeElement(unpack(currentElement)) end
			end
			return true
		end
	end

	local function findElementClose()
		first, last, match1, match2 = find( xml, '^</([%a_][%w_.-]*)%s*>', pos )
		if first then
			nsURI = nil
			for i=#nsStack,1,-1 do if nsStack[i]['!'] then nsURI = nsStack[i]['!']; break end end
		else
			first, last, match2, match1 = find( xml, '^</([%a_][%w_.-]*):([%a_][%w_.-]*)%s*>', pos )
			if first then nsURI = nsForPrefix(match2) end
		end
		if first then
			finishText()
			if self._call.closeElement then self._call.closeElement(match1,nsURI) end
			pos = last+1
			textStart = pos
			pop(nsStack)
			return true
		end
	end

	while pos<#xml do
		if state=="text" then
			if not (findPI() or findComment() or findCDATA() or findElementClose()) then		
				if startElement() then
					state = "attributes"
				else
					first, last = find( xml, '^[^<]+', pos )
					pos = (first and last or pos) + 1
				end
			end
		elseif state=="attributes" then
			if not findAttribute() then
				if not closeElement() then
					error("Was in an element and couldn't find attributes or the close.")
				end
			end
		end
	end
end

return SLAXML
end)()
function LXSC:parse(scxml)
	local push, pop = table.insert, table.remove
	local i, stack = 1, {}
	local current, root
	local stateKinds = LXSC.State.stateKinds
	local scxmlNS    = LXSC.scxmlNS
	local parser = SLAXML:parser{
		startElement = function(name,nsURI)
			local item
			if nsURI == scxmlNS then
				if stateKinds[name] then
					item = LXSC:state(name)
				else
					item = LXSC[name](LXSC,name,nsURI)
				end
			else
				item = LXSC:_generic(name,nsURI)
			end
			item._order = i; i=i+1
			if current then current:addChild(item) end
			current = item
			if not root then root = current end
			push(stack,item)
		end,
		attribute = function(name,value) current:attr(name,value) end,
		closeElement = function(name)
			if current._kind ~= name then
				error(string.format("I was working with a '%s' element but got a close notification for '%s'",current._kind,name))
			end
			if name=="transition" then
				table.insert( current.source[current.events and '_eventedTransitions' or '_eventlessTransitions'], current )
			end
			pop(stack)
			current = stack[#stack] or current
		end,
		text = function(text)
			current._text = text
		end
	}
	parser:parse(scxml,{stripWhitespace=true})
	return root
end
return LXSC
