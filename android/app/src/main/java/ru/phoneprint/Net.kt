package ru.phoneprint

import android.content.ContentResolver
import android.net.Uri
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Что печатаем: файл (uri) или набранный текст. */
class PrintItem(
    val uri: Uri?,
    val text: String?,
    val name: String,
    val size: Long,
    /** size точно известен — можно отправлять с Content-Length, иначе chunked */
    val exactSize: Boolean,
) {
    enum class State { WAIT, UPLOAD, PRINTING, DONE, ERROR }

    var state = State.WAIT
    var progress = 0f
    var message = ""
}

/** Общение с PhonePrint на компьютере (тот же API, что у веб-страницы). */
object Net {
    const val PORT = 8080

    /** Как encodeURIComponent: сервер декодирует через Uri.UnescapeDataString, «+» он не превращает в пробел. */
    fun enc(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

    /**
     * Ответ PhonePrint на /api/info. Если на ПК задан PIN, а он не передан или неверный, сервер отвечает
     * 401 (поле error = "pin") или 429 (error = "locked") — такой ответ тоже возвращаем, чтобы показать запрос PIN.
     * null — по адресу не PhonePrint или нет связи.
     */
    fun info(base: String, pin: String = "", connectTimeout: Int = 3000): JSONObject? = try {
        val c = URL("$base/api/info").openConnection() as HttpURLConnection
        c.connectTimeout = connectTimeout
        c.readTimeout = 10_000
        if (pin.isNotEmpty()) c.setRequestProperty("X-Pin", enc(pin))
        try {
            val code = c.responseCode
            val body = (if (code < 400) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() }
            body?.let { JSONObject(it) }?.takeIf { it.optString("app") == "PhonePrint" && (code == 200 || it.has("error")) }
        } finally {
            c.disconnect()
        }
    } catch (e: Exception) {
        null
    }

    /** Ищет компьютер с PhonePrint в локальной сети (перебор x.x.x.1–254 на порту 8080). */
    fun discover(pin: String = ""): Pair<String, JSONObject>? {
        val own = try {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
                .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
                .sortedByDescending { it.name.startsWith("wlan") }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .filter { it.isSiteLocalAddress }
        } catch (e: Exception) {
            emptyList()
        }
        if (own.isEmpty()) return null

        val hosts = own.flatMap { addr ->
            val b = addr.address
            val prefix = "${b[0].toInt() and 255}.${b[1].toInt() and 255}.${b[2].toInt() and 255}"
            (1..254).map { "$prefix.$it" }.filter { it != addr.hostAddress }
        }.distinct()

        val pool = Executors.newFixedThreadPool(48)
        return try {
            val tasks = hosts.map { host ->
                Callable {
                    Socket().use { it.connect(InetSocketAddress(host, PORT), 600) }
                    val base = "http://$host:$PORT"
                    val info = info(base, pin) ?: throw IOException("not PhonePrint")
                    base to info
                }
            }
            pool.invokeAny(tasks, 30, TimeUnit.SECONDS)
        } catch (e: Exception) {
            null
        } finally {
            pool.shutdownNow()
        }
    }

    /** Отправляет файл на печать. Возвращает (успех, сообщение сервера). */
    fun upload(
        cr: ContentResolver,
        base: String,
        item: PrintItem,
        copies: Int,
        pages: String,
        printer: String,
        pin: String,
        onProgress: (Float) -> Unit,
        onSent: () -> Unit,
    ): Pair<Boolean, String> {
        val c = URL("$base/api/print?copies=$copies&pages=${enc(pages)}").openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.doOutput = true
            c.connectTimeout = 5_000
            c.readTimeout = 15 * 60 * 1000          // сервер отвечает, когда задание ушло в очередь Windows
            c.setRequestProperty("Content-Type", "application/octet-stream")
            c.setRequestProperty("X-File-Name", enc(item.name))
            c.setRequestProperty("X-Printer", enc(printer))
            if (pin.isNotEmpty()) c.setRequestProperty("X-Pin", enc(pin))

            val data = item.text?.toByteArray(Charsets.UTF_8)
            val total = data?.size?.toLong() ?: item.size
            if (data != null || item.exactSize) c.setFixedLengthStreamingMode(total)
            else c.setChunkedStreamingMode(64 * 1024)

            val input = data?.inputStream()
                ?: item.uri?.let { cr.openInputStream(it) }
                ?: throw IOException("Не удалось открыть файл")
            input.use { inp ->
                c.outputStream.use { out ->
                    val buf = ByteArray(64 * 1024)
                    var sent = 0L
                    while (true) {
                        val n = inp.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        sent += n
                        if (total > 0) onProgress((sent.toFloat() / total).coerceAtMost(1f))
                    }
                }
            }
            onSent()

            val code = c.responseCode
            val body = (if (code < 400) c.inputStream else c.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            val json = runCatching { JSONObject(body) }.getOrNull()
                ?: return false to "Ошибка на компьютере ($code)"
            return json.optBoolean("ok") to json.optString("message")
        } finally {
            c.disconnect()
        }
    }
}
