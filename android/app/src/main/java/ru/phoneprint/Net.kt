package ru.phoneprint

import android.content.ContentResolver
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
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

    /**
     * Привязывает сетевые запросы приложения к Wi-Fi/Ethernet. Если у Wi-Fi нет интернета (роутер без выхода
     * в сеть, чужая сеть с порталом авторизации), Android по умолчанию гонит весь трафик через мобильный интернет,
     * и компьютер с адресом 192.168.x.x оттуда не виден — хотя телефон к тому же Wi-Fi подключён.
     */
    fun bindToLan(ctx: Context) {
        try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            @Suppress("DEPRECATION")
            val lan = cm.allNetworks.firstOrNull { n ->
                val caps = cm.getNetworkCapabilities(n)
                caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
            }
            cm.bindProcessToNetwork(lan)    // null — вернуть выбор системе (например, если Wi-Fi выключен)
        } catch (e: Exception) {
            // не критично: тогда работаем как раньше, по выбору системы
        }
    }

    /** Свой адрес в локальной сети и длина маски (24 = 255.255.255.0). */
    private class Lan(val addr: Inet4Address, val prefix: Int)

    private fun localNets(): List<Lan> = try {
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
            .sortedByDescending { it.name.startsWith("wlan") || it.name.startsWith("eth") }
            .flatMap { it.interfaceAddresses }
            .mapNotNull { ia -> (ia.address as? Inet4Address)?.takeIf { it.isSiteLocalAddress }?.let { Lan(it, ia.networkPrefixLength.toInt()) } }
    } catch (e: Exception) {
        emptyList()
    }

    /** Адреса телефона в локальной сети (для подсказки, если компьютер не нашёлся). */
    fun ownAddresses(): List<String> = localNets().mapNotNull { it.addr.hostAddress }

    /** Ищет компьютер с PhonePrint в локальной сети (перебор адресов своей подсети на порту 8080). */
    fun discover(pin: String = ""): Pair<String, JSONObject>? {
        val own = localNets()
        if (own.isEmpty()) return null

        // Сначала свои x.x.x.1–254, потом остальная подсеть, если маска шире /24 (но не больше /22 — это 1022 адреса)
        val hosts = own.flatMap { lan ->
            val me = lan.addr.address.fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 255) }
            val mask = (-1 shl (32 - lan.prefix.coerceIn(22, 30)))
            val net = me and mask
            val bcast = net or mask.inv()
            val ownBlock = me and 0xFFFFFF00.toInt()
            fun ip(v: Int) = "${v ushr 24}.${(v shr 16) and 255}.${(v shr 8) and 255}.${v and 255}"
            (net + 1 until bcast).filter { it != me }
                .sortedBy { if ((it and 0xFFFFFF00.toInt()) == ownBlock) 0 else 1 }
                .map(::ip)
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
        duplex: Boolean,
        pin: String,
        onProgress: (Float) -> Unit,
        onSent: () -> Unit,
    ): Pair<Boolean, String> {
        val c = URL("$base/api/print?copies=$copies&pages=${enc(pages)}${if (duplex) "&duplex=1" else ""}").openConnection() as HttpURLConnection
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
