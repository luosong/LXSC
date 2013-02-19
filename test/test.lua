package.path = "../?.lua;" .. package.path
require 'io'
require 'lunity'
LXSC = require 'lxsc'

module( 'TEST_LXSC', lunity )

DIR = 'testcases'
SHOULD_NOT_FINISH = {final2=true}

XML = {}
for filename in io.popen(string.format('ls "%s"',DIR)):lines() do
	local testName = filename:sub(1,-7)
	XML[testName] = io.open(DIR.."/"..filename):read("*all")
end

function test0_parsing()
	local m = LXSC:parse(XML['internal_transition'])
	assertNil(m.id,"The scxml should not have an id")
	assertTrue(m.isCompound,'The root state should be compound')
	assertEqual(m.states[1].id,'outer')
	assertEqual(m.states[2].id,'fail')
	assertEqual(m.states[3].id,'pass')
	assertEqual(#m.states,3,"internal_transition.scxml should have 3 root states")
	local outer = m.states[1]
	assertEqual(#outer.states,2,"There should be 2 child states of the 'outer' state")
	assertEqual(#outer._onexits,1,"There should be 1 onexit command for the 'outer' state")
	assertEqual(#outer._onentrys,0,"There should be 0 onentry commands for the 'outer' state")

	m = LXSC:parse(XML['history'])
	assertSameKeys(m:allStateIds(),{["wrap"]=1,["universe"]=1,["history-actions"]=1,["action-1"]=1,["action-2"]=1,["action-3"]=1,["action-4"]=1,["modal-dialog"]=1,["pass"]=1,["fail"]=1})
	assertSameKeys(m:atomicStateIds(),{["history-actions"]=1,["action-1"]=1,["action-2"]=1,["action-3"]=1,["action-4"]=1,["modal-dialog"]=1,["pass"]=1,["fail"]=1})

	m = LXSC:parse(XML['parallel4'])
	assertSameKeys(m:allStateIds(),{["wrap"]=1,["p"]=1,["a"]=1,["a1"]=1,["a2"]=1,["b"]=1,["b1"]=1,["b2"]=1,["pass"]=1})
	assertSameKeys(m:atomicStateIds(),{["a1"]=1,["a2"]=1,["b1"]=1,["b2"]=1,["pass"]=1})
end

function test1_dataAccess()
	local s = LXSC:parse[[<scxml xmlns='http://www.w3.org/2005/07/scxml' version='1.0'>
		<script>boot(); boot()</script>
		<datamodel><data id="n" expr="0"/></datamodel>
		<state id='s'>
			<transition event="error.execution" target="errord"/>
			<transition cond="n==7" target="pass"/>
		</state>
		<final id="pass"/><final id="errord"/>
	</scxml>]]

	s:start()
	assert(s:isActive('errord'),"There should be an error when boot() can't be found")

	s:start{ data={ boot=function() end } }
	assert(s:isActive('s'),"There should be no error when boot() is supplied")

	-- s:start{ data={ boot=function() n=7 end } }
	-- assert(s:isActive('pass'),"Setting 'global' variables populates data model")

	s:start{ data={ boot=function() end, m=42 } }
	assertEqual(s:get("m"),42,"The data model should accept initial values")

	s:set("foo","bar")
	s:set("jim",false)
	s:set("n",6)
	assertEqual(s:get("foo"),"bar")
	assertEqual(s:get("jim"),false)
	assertEqual(s:get("n")*7,42)

	s:start()
	assertNil(s:get("boot"),"Starting the machine resets the datamodel")
	assertNil(s:get("foo"),"Starting the machine resets the datamodel")

	s:start{ data={ boot=function() end, n=6 } }
	assert(s:isActive('s'))
	s:set("n",7)
	assert(s:isActive('s'))
	s:step()
	assert(s:isActive('pass'))

	s:restart()
	assert(s:isActive('errord'))

	local s = LXSC:parse[[<scxml xmlns='http://www.w3.org/2005/07/scxml' version='1.0'><state/></scxml>]]
	local values = {}
	s.onDataSet = function(name,value) values[name]=value end
	s:start()
	assertNil(values.foo)
	s:set("foo",42)
	assertEqual(values.foo,42)
end

function test2_eventlist()
	local m = LXSC:parse[[
		<scxml xmlns='http://www.w3.org/2005/07/scxml' version='1.0'>
			<parallel>
				<state>
					<transition event="a b.c" target="x"/>
					<state><transition event="d.e.f g.*" target="x"/></state>
				</state>
				<state><transition event="h." target="x"/></state>
			</parallel>
			<state id="x"><transition event="x y.z" target="x" /></state>
		</scxml>]]
	local possible = m:allEvents()
	local expected = {["a"]=1,["b.c"]=1,["d.e.f"]=1,["g"]=1,["h"]=1,["x"]=1,["y.z"]=1}
	assertSameKeys(possible,expected)

	assertNil(next(m:availableEvents()),"There should be no events before the machine has started.")
	m:start()

	local available = m:availableEvents()
	local expected = {["a"]=1,["b.c"]=1,["d.e.f"]=1,["g"]=1,["h"]=1}
	assertSameKeys(available,expected)
end

function test3_customHandlers()
	local s = LXSC:parse[[
		<scxml xmlns='http://www.w3.org/2005/07/scxml' version='1.0'
			xmlns:a="foo" xmlns:b="bar">
			<state><onentry><a:go/><b:go/></onentry></state>
		</scxml>
	]]
	local goSeen = {}
	function LXSC.Exec:go() goSeen[self._nsURI] = true end
	assertNil(goSeen.foo)
	assertNil(goSeen.bar)
	s:start()
	assertTrue(goSeen.foo)
	assertTrue(goSeen.bar)
end

for testName,xml in pairs(XML) do
	_M["testcase-"..testName] = function()
		local machine = LXSC:parse(xml)
		assertFalse(machine.running, testName.." should not be running before starting.")
		assertTableEmpty(machine:activeStateIds(), testName.." should be empty before running.")
		machine:start()
		assert(machine:activeStateIds().pass, testName.." should finish in the 'pass' state.")
		assertEqual(#machine:activeAtomicIds(), 1, testName.." should only have a single atomic state active.")
		if SHOULD_NOT_FINISH[testName] then
			assertTrue(machine.running, testName.." should NOT run to completion.")
		else
			assertFalse(machine.running, testName.." should run to completion.")
		end
	end
end

runTests{ useANSI=false }
