package com.tekartik.sqflite

import com.tekartik.sqflite.operation.MethodCallOperation
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

/** Exercise the actual sqflite Android adapter, rather than desktop SQLite.
 * Read startup SQL and its dispatch method from production Dart so accidentally
 * switching a row-producing PRAGMA back to execute fails this regression. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 34], manifest = Config.NONE)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class DatabaseStartupTest {
    private class Result : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var completed = false
        override fun success(result: Any?) { value = result; completed = true }
        override fun error(code: String, message: String?, details: Any?) {
            error = "$code: $message"; completed = true
        }
        override fun notImplemented() { throw AssertionError("SQL method unavailable") }
    }

    private fun call(db: Database, method: String, sql: String): Result {
        val result = Result()
        val operation = MethodCallOperation(MethodCall(method,
            mapOf("sql" to sql, "arguments" to emptyList<Any>())), result)
        if (method == "rawQuery") db.query(operation) else db.execute(operation)
        assertTrue("SQL operation did not complete", result.completed)
        return result
    }

    private fun configure(db: Database) {
        val source = File("../../lib/store.dart").readText()
        val callback = source.substringAfter("onConfigure: (db) async {")
            .substringBefore("onUpgrade:")
        val operations = Regex("db\\.(execute|rawQuery)\\('([^']+)'\\)")
            .findAll(callback).toList()
        assertEquals("Expected both production connection settings", 2, operations.size)
        for (op in operations) {
            val result = call(db, op.groupValues[1], op.groupValues[2])
            assertNull("Startup failed: ${result.error}", result.error)
        }
        val timeout = call(db, "rawQuery", "PRAGMA busy_timeout").value as Map<*, *>
        assertEquals(listOf(listOf(5000L)), timeout["rows"])
        val durability = call(db, "rawQuery", "PRAGMA synchronous").value as Map<*, *>
        assertEquals(listOf(listOf(2L)), durability["rows"])
    }

    @Test fun startupSettingsWorkOnFreshAndExistingAndroidDatabase() {
        val app = RuntimeEnvironment.getApplication()
        val file = File(app.cacheDir, "startup-regression.sqlite3")
        Database.deleteDatabase(file.path)
        val db = Database(app, file.path, 1, false, 0)
        db.open()
        try {
            configure(db)
            assertNull(call(db, "execute", "CREATE TABLE preserved(value TEXT)").error)
            assertNull(call(db, "execute", "INSERT INTO preserved VALUES ('saved keys and queue')").error)
        } finally { db.close() }
        val reopened = Database(app, file.path, 2, false, 0)
        reopened.open()
        try {
            configure(reopened)
            val rows = call(reopened, "rawQuery", "SELECT value FROM preserved").value as Map<*, *>
            assertEquals(listOf(listOf("saved keys and queue")), rows["rows"])
        } finally { reopened.close(); Database.deleteDatabase(file.path) }
    }

    @Test fun executeRejectsRowProducingPragmaAsInReportedStartupFailure() {
        val db = Database(RuntimeEnvironment.getApplication(), ":memory:", 3, false, 0)
        db.open()
        try {
            val original = call(db, "execute", "PRAGMA busy_timeout=5000")
            assertNotNull("Must reproduce Android's execSQL restriction", original.error)
            assertTrue(original.error!!, original.error!!.contains("query") ||
                original.error!!.contains("Queries"))
        } finally { db.close() }
    }
}
