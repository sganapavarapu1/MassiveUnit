/****
* Copyright 2013 Massive Interactive. All rights reserved.
* 
* Redistribution and use in source and binary forms, with or without modification, are
* permitted provided that the following conditions are met:
* 
*    1. Redistributions of source code must retain the above copyright notice, this list of
*       conditions and the following disclaimer.
* 
*    2. Redistributions in binary form must reproduce the above copyright notice, this list
*       of conditions and the following disclaimer in the documentation and/or other materials
*       provided with the distribution.
* 
* THIS SOFTWARE IS PROVIDED BY MASSIVE INTERACTIVE ``AS IS'' AND ANY EXPRESS OR IMPLIED
* WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
* FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL MASSIVE INTERACTIVE OR
* CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
* CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
* SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
* ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
* NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
* ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
* 
* The views and conclusions contained in the software and documentation are those of the
* authors and should not be interpreted as representing official policies, either expressed
* or implied, of Massive Interactive.
****/

package massive.munit;

import haxe.PosInfos;

import massive.munit.Assert;
import massive.munit.async.AsyncDelegate;
import massive.munit.async.AsyncFactory;
import massive.munit.async.AsyncTimeoutException;
import massive.munit.async.IAsyncDelegateObserver;
import massive.munit.async.MissingAsyncDelegateException;
import massive.munit.async.UnexpectedAsyncDelegateException;
import massive.munit.util.Timer;
import massive.munit.ITestResultClient;
import massive.munit.TestResult;

#if neko
import neko.vm.Thread;
#elseif cpp
import cpp.vm.Thread;
#end

using Lambda;
#if haxe3
import haxe.CallStack;
#else
import haxe.Stack;
private typedef CallStack = Stack;
#end

/**
 * Runner used to execute one or more suites of unit tests.
 *
 * <pre>
 * // Create a test runner with client (PrintClient) and pass it a collection of test suites
 * public class TestMain
 * {
 *     public function new()
 *     {
 *         var suites = new Array<Class<massive.munit.TestSuite>>();
 *         suites.push(TestSuite);
 *
 *         var runner:TestRunner = new TestRunner(new PrintClient());
 *         runner.run(suites);
 *     }
 * }
 *
 * // A test suite with one test class (MathUtilTest)
 * class TestSuite extends massive.unit.TestSuite
 * {
 *     public function new()
 *     {
 *          add(MathUtilTest);
 *     }
 * }
 *
 * // A test class with one test case (testAdd)
 * class MathUtilTest
 * {
 *     @Test
 *     public function testAdd():Void
 *     {
 *         Assert.areEqual(2, MathUtil.add(1,1));
 *     }
 * }
 * </pre>
 * @author Mike Stead
 * @see TestSuite
 */
class TestRunner implements IAsyncDelegateObserver
{
    /**
     * The currently active TestRunner.  Will be null if no test is executing.
     **/
    public static var activeRunner(default, null):TestRunner;

    /**
     * Handler called when all tests have been executed and all clients
     * have completed processing the results.
     */
    public var completionHandler:Bool -> Void;

    public var clientCount(get_clientCount, null):Int;
    private function get_clientCount():Int { return clients.length; }

    public var running(default, null):Bool;

    private var testCount:Int;
    private var failCount:Int;
    private var errorCount:Int;
    private var passCount:Int;
    private var ignoreCount:Int;
    private var clientCompleteCount:Int;

    private var clients:Array<ITestResultClient>;

    private var activeHelper:TestClassHelper;
    private var testSuites:Array<TestSuite>;

    private var asyncDelegates:Array<AsyncDelegate>; // array to support multiple async handlers (chaining, or simultaneous)
    private var suiteIndex:Int;

    public var asyncFactory(default, set_asyncFactory):AsyncFactory;
    private function set_asyncFactory(value:AsyncFactory):AsyncFactory
    {
        if (value == asyncFactory) return value;
        if (running) throw new MUnitException("Can't change AsyncFactory while tests are running");
        value.observer = this;
        return asyncFactory = value;
    }

    private var emptyParams:Array<Dynamic>;

    private var startTime:Float;
    private var testStartTime:Float;

    private var isDebug(default, null):Bool;


    /**
     * Class constructor.
     *
     * @param	resultClient	a result client to interpret test results
     */
    public function new(resultClient:ITestResultClient)
    {
        clients = new Array<ITestResultClient>();
        addResultClient(resultClient);
        asyncFactory = createAsyncFactory();
        running = false;

        #if (testDebug||testdebug)
        isDebug = true;
        #else
        isDebug = false;
        #end
    }

    /**
     * Add one or more result clients to interpret test results.
     *
     * @param	resultClient			a result client to interpret test results
     */
    public function addResultClient(resultClient:ITestResultClient):Void
    {
        for (client in clients) if (client == resultClient) return;

        resultClient.completionHandler = clientCompletionHandler;
        clients.push(resultClient);
    }


    /**
     * Run one or more suites of unit tests containing @TestDebug.
     *
     * @param	testSuiteClasses
     */
    public function debug(testSuiteClasses:Array<Class<TestSuite>>):Void
    {
        isDebug = true;
        run(testSuiteClasses);
    }

    /**
     * Run one or more suites of unit tests.
     *
     * @param	testSuiteClasses
     */
    public function run(testSuiteClasses:Array<Class<TestSuite>>):Void
    {
        if (running) return;

        running = true;
        activeRunner = this;
        testCount = 0;
        failCount = 0;
        errorCount = 0;
        passCount = 0;
        ignoreCount = 0;
        suiteIndex = 0;
        clientCompleteCount = 0;
        Assert.assertionCount = 0; // don't really like this static but can't see way around it atm. ms 17/12/10
        emptyParams = new Array();
        asyncDelegates = new Array<AsyncDelegate>();
        testSuites = new Array<TestSuite>();
        startTime = Timer.stamp();

        for (suiteType in testSuiteClasses)
        {
            testSuites.push(Type.createInstance(suiteType, new Array()));
        }

        #if (!nme && (neko||cpp))
            var self = this;
            var runThread:Thread = Thread.create(function()
            {
                self.execute();
                while (self.running)
                {
                    Sys.sleep(.2);
                }
                var mainThead:Thread = Thread.readMessage(true);
                mainThead.sendMessage("done");
            });

            runThread.sendMessage(Thread.current());
            Thread.readMessage(true);
        #else
            execute();
        #end
    }

    private function callHelperMethod ( method:Dynamic ):Void
    {
        try
        {
            /*
                Wrapping in try/catch solves below problem:
                    If @BeforeClass, @AfterClass, @Before, @After methods
                    have any Assert calls that fail, and if they are not
                    caught and handled here ... then TestRunner stalls.
            */
            Reflect.callMethod(activeHelper.test, method, emptyParams);
        }
        catch (e:Dynamic)
        {
            var testcaseData: Dynamic = activeHelper.current(); // fetch the test context
            exceptionHandler ( e, testcaseData.result );
        }
    }


    private inline function exceptionHandler ( e:Dynamic, result:TestResult ):Void
    {
        if (Std.is(e, org.hamcrest.AssertionException))
        {
            e = new AssertionException(e.message, e.info);
        }

        result.executionTime = Timer.stamp() - testStartTime;

        if (Std.is(e, AssertionException))
        {
            result.failure = e;
            failCount++;
            for (c in clients)
                c.addFail(result);
        }
        else
        {
            if (!Std.is(e, MUnitException))
                e = new UnhandledException(e, result.location);

            result.error = e;
            errorCount++;
            for (c in clients)
                c.addError(result);
        }
    }


    private function execute():Void
    {
        for (i in suiteIndex...testSuites.length)
        {
            var suite:TestSuite = testSuites[i];
            for (testClass in suite)
            {
                if (activeHelper == null || activeHelper.type != testClass)
                {
                    activeHelper = new TestClassHelper(testClass, isDebug);
                    activeHelper.beforeClass.iter(callHelperMethod);
                }
                executeTestCases();
                if ( ! isAsyncPending() )
                {
                    activeHelper.afterClass.iter(callHelperMethod);
                }
                else
                {
                    suite.repeat();
                    suiteIndex = i;
                    return;
                }
            }
        }

        if ( ! isAsyncPending() )
        {
            var time:Float = Timer.stamp() - startTime;
            for (client in clients)
            {
                if(Std.is(client, IAdvancedTestResultClient))
                {
                    cast(client, IAdvancedTestResultClient).setCurrentTestClass(null);
                }
                client.reportFinalStatistics(testCount, passCount, failCount, errorCount, ignoreCount, time);
            } 
        }
    }

    private function executeTestCases():Void
    {
        for(c in clients)
        {
            if(Std.is(c, IAdvancedTestResultClient))
            {
                cast(c, IAdvancedTestResultClient).setCurrentTestClass(activeHelper.className);
            }
        }
        for (testCaseData in activeHelper)
        {
            if (testCaseData.result.ignore)
            {
                ignoreCount++;
                for (c in clients)
                    c.addIgnore(cast testCaseData.result);
            }
            else
            {
                testCount++; // note we don't include ignored in final test count
                activeHelper.before.iter(callHelperMethod);
                testStartTime = Timer.stamp();
                executeTestCase(testCaseData);

                if ( ! isAsyncPending() ) {
                    activeRunner = null;  // for SYNC tests: resetting this here instead of clientCompletionHandler
                    activeHelper.after.iter(callHelperMethod);
                }
                else
                    break;
            }
        }
    }

    private function executeTestCase(testCaseData:Dynamic):Void
    {
        var result:TestResult = testCaseData.result;
        try
        {
            var assertionCount:Int = Assert.assertionCount;

            // This was being reset to null when testing TestRunner itself i.e. testing munit using munit.
            // By setting this here, this runner value will be valid right when tests (Sync/ASync) are about to run.
            activeRunner = this;

            Reflect.callMethod(testCaseData.scope, testCaseData.test, result.args);

            if (! isAsyncPending())
            {
                result.passed = true;
                result.executionTime = Timer.stamp() - testStartTime;
                passCount++;
                for (c in clients)
                    c.addPass(result);
            }
        }
        catch(e:Dynamic)
        {
            cancelAllPendingAsyncTests();
            exceptionHandler ( e, result );
        }
    }

    private function clientCompletionHandler(resultClient:ITestResultClient):Void
    {
        if (++clientCompleteCount == clients.length)
        {
            if (completionHandler != null)
            {
                var successful:Bool = (passCount == testCount);
                var handler:Dynamic = completionHandler;

                Timer.delay(function() { handler(successful); }, 10);
            }
            running = false;
        }
    }

    /**
     * Called when an AsyncDelegate being observed receives a successful asynchronous callback.
     *
     * @param	delegate		delegate which received the successful callback
     */
    public function asyncResponseHandler(delegate:AsyncDelegate):Void
    {
        var testCaseData:Dynamic = activeHelper.current();
        testCaseData.test = delegate.runTest;
        testCaseData.scope = delegate;

        asyncDelegates.remove(delegate);
        executeTestCase(testCaseData);
        if ( ! isAsyncPending() ) {
            activeRunner = null; // for ASync regular cases: resetting this here instead of clientCompletionHandler
            activeHelper.after.iter(callHelperMethod);
            execute();
        }
    }

    /**
     * Called when an AsyncDelegate being observed does not receive its asynchronous callback
     * in the time allowed.
     *
     * @param	delegate		delegate whose asynchronous callback timed out
     */
    public function asyncTimeoutHandler(delegate:AsyncDelegate):Void
    {
        var testCaseData:Dynamic = activeHelper.current();
        asyncDelegates.remove(delegate);

        if (delegate.hasTimeoutHandler)
        {
            testCaseData.test = delegate.runTimeout;
            testCaseData.scope = delegate;
            executeTestCase(testCaseData);
        }
        else
        {
            cancelAllPendingAsyncTests();

            var result:TestResult = testCaseData.result;
            result.executionTime = Timer.stamp() - testStartTime;
            result.error = new AsyncTimeoutException("", delegate.info);

            errorCount++;
            for (c in clients) c.addError(result);
        }
        if ( ! isAsyncPending() ) {
             activeRunner = null; // for ASync Time-out cases: resetting this here instead of clientCompletionHandler
             activeHelper.after.iter(callHelperMethod);
             execute();
        }
    }

    public function asyncDelegateCreatedHandler(delegate:AsyncDelegate):Void
    {
        asyncDelegates.push(delegate);
    }

    private function createAsyncFactory():AsyncFactory
    {
        return new AsyncFactory(this);
    }

    private inline function isAsyncPending() : Bool
    {
        return (asyncDelegates.length > 0);
    }

    private function cancelAllPendingAsyncTests() : Void
    {
        for (delegate in asyncDelegates)
        {
            delegate.cancelTest();
            asyncDelegates.remove(delegate);
        }
    }
}
