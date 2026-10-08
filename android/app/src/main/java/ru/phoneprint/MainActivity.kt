package ru.phoneprint

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.view.Gravity
import android.view.View
import android.webkit.MimeTypeMap
import android.widget.ArrayAdapter
import android.widget.AdapterView
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import androidx.core.content.IntentCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONObject
import java.io.File
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : Activity() {

    private companion object {
        const val REQ_FILES = 1
        const val REQ_CAMERA = 2
        const val KEY_CAMERA_FILE = "cameraFile"
        // Новый ключ: в версии 1 здесь сохранялось имя HP даже без выбора пользователя
        const val KEY_PRINTER = "printerChoice"
        const val KEY_DUPLEX = "duplex"
        val PAGES_RE = Regex("^\\d+(-\\d+)?(,\\d+(-\\d+)?)*$")
        val MIME_TYPES = arrayOf(
            "application/pdf", "image/*", "text/plain", "text/csv", "text/comma-separated-values",
            "application/msword", "application/rtf", "text/rtf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.oasis.opendocument.text",
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.oasis.opendocument.spreadsheet",
        )
    }

    private val items = mutableListOf<PrintItem>()
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var prefs: SharedPreferences

    private var pin = ""                        // PIN-код, заданный на компьютере (пусто = не задан)
    private var pinDialog: AlertDialog? = null
    private var duplexSupport: Map<String, Boolean> = emptyMap()   // имя принтера на ПК -> умеет двустороннюю печать
    private var defaultPrinterName = ""
    private var server: String? = null          // http://192.168.1.50:8080
    private var copies = 1
    private var busy = false
    private var connecting = false
    private var cameraFile: File? = null
    private var lastRender = 0L
    private var printerValues: List<String> = emptyList()   // "" = принтер по умолчанию на ПК

    private lateinit var status: TextView
    private lateinit var queue: LinearLayout
    private lateinit var history: LinearLayout
    private lateinit var historyTitle: TextView
    private lateinit var copiesView: TextView
    private lateinit var pages: EditText
    private lateinit var printer: Spinner
    private lateinit var duplexBox: View
    private lateinit var duplex: CheckBox
    private lateinit var btnPrint: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = getSharedPreferences("settings", MODE_PRIVATE)
        server = prefs.getString("server", null)
        pin = prefs.getString("pin", "").orEmpty()
        cameraFile = savedInstanceState?.getString(KEY_CAMERA_FILE)?.let(::File)

        status = findViewById(R.id.status)
        queue = findViewById(R.id.queue)
        history = findViewById(R.id.history)
        historyTitle = findViewById(R.id.historyTitle)
        copiesView = findViewById(R.id.copies)
        pages = findViewById(R.id.pages)
        printer = findViewById(R.id.printer)
        duplexBox = findViewById(R.id.duplexBox)
        duplex = findViewById(R.id.duplex)
        duplex.isChecked = prefs.getBoolean(KEY_DUPLEX, false)
        duplex.setOnCheckedChangeListener { _, on -> prefs.edit().putBoolean(KEY_DUPLEX, on).apply() }
        printer.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) = updateDuplexVisibility()
            override fun onNothingSelected(p: AdapterView<*>?) = Unit
        }
        btnPrint = findViewById(R.id.btnPrint)

        applyInsets()
        findViewById<Button>(R.id.btnFiles).setOnClickListener { pickFiles() }
        findViewById<Button>(R.id.btnPhoto).setOnClickListener { takePhoto() }
        findViewById<Button>(R.id.btnText).setOnClickListener { showTextDialog() }
        findViewById<ImageButton>(R.id.btnSettings).setOnClickListener { showSettings() }
        findViewById<Button>(R.id.btnMinus).setOnClickListener { setCopies(copies - 1) }
        findViewById<Button>(R.id.btnPlus).setOnClickListener { setCopies(copies + 1) }
        btnPrint.setOnClickListener { startPrint() }

        handleShare(intent)
        render()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
        render()
    }

    override fun onResume() {
        super.onResume()
        if (!busy) refresh(discover = true)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        cameraFile?.let { outState.putString(KEY_CAMERA_FILE, it.absolutePath) }
    }

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }

    // Android 15 рисует приложение под системными панелями — отодвигаем контент сами.
    private fun applyInsets() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.root)) { v, insets ->
            val i = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.ime())
            v.setPadding(i.left, i.top, i.right, i.bottom)
            insets
        }
    }

    // ---------- что печатать ----------

    private fun handleShare(intent: Intent?) {
        intent ?: return
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                if (uri != null) addUri(uri)
                else intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }?.let(::addText)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                    ?.forEach(::addUri)
            }
        }
        intent.action = null      // чтобы при повороте/возврате не добавить файлы второй раз
    }

    private fun addUri(uri: Uri) {
        var name: String? = null
        var size = -1L
        var exact = false
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        name = c.getString(0)
                        if (!c.isNull(1)) size = c.getLong(1)
                    }
                }
        } catch (_: Exception) {
        }
        try {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use {
                if (it.length >= 0) { size = it.length; exact = true }
            }
        } catch (_: Exception) {
        }
        var n = name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        if (!n.contains('.')) {
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(contentResolver.getType(uri))
            if (ext != null) n += ".$ext"
        }
        items.add(PrintItem(uri, null, n, size, exact))
    }

    private fun addText(text: String) {
        items.add(PrintItem(null, text, "Текст.txt", text.toByteArray().size.toLong(), true))
    }

    private fun pickFiles() {
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, MIME_TYPES)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            startActivityForResult(i, REQ_FILES)
        } catch (e: ActivityNotFoundException) {
            toast("Не найдено приложение для выбора файлов")
        }
    }

    private fun takePhoto() {
        val dir = File(cacheDir, "camera").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }     // старые снимки уже не нужны
        val f = File(dir, "photo_${System.currentTimeMillis()}.jpg")
        cameraFile = f
        val uri = FileProvider.getUriForFile(this, "ru.phoneprint.files", f)
        val i = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivityForResult(i, REQ_CAMERA)
        } catch (e: ActivityNotFoundException) {
            toast("Не найдено приложение камеры")
        }
    }

    @Deprecated("Activity без AndroidX")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK) return
        when (requestCode) {
            REQ_FILES -> {
                val clip = data?.clipData
                if (clip != null) for (i in 0 until clip.itemCount) addUri(clip.getItemAt(i).uri)
                else data?.data?.let(::addUri)
            }
            REQ_CAMERA -> {
                val f = cameraFile
                if (f != null && f.length() > 0) {
                    val stamp = SimpleDateFormat("HH-mm-ss", Locale.ROOT).format(Date())
                    items.add(PrintItem(Uri.fromFile(f), null, "Фото_$stamp.jpg", f.length(), true))
                }
            }
        }
        render()
    }

    private fun showTextDialog() {
        val input = EditText(this).apply {
            minLines = 5
            gravity = Gravity.TOP or Gravity.START
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            hint = "Вставьте или наберите текст"
        }
        AlertDialog.Builder(this)
            .setTitle("Текст для печати")
            .setView(padded(input))
            .setPositiveButton("Добавить") { _, _ ->
                val t = input.text.toString()
                if (t.isNotBlank()) { addText(t); render() }
            }
            .setNegativeButton("Отмена", null)
            .show()
    }

    // ---------- подключение к компьютеру ----------

    private fun refresh(discover: Boolean) {
        if (connecting) return
        connecting = true
        val saved = server
        if (saved == null) status.text = "Ищу компьютер в сети…"
        Net.bindToLan(this)     // иначе при Wi-Fi без интернета запросы уходят в мобильную сеть
        Thread {
            var base = saved
            var info = saved?.let { Net.info(it, pin) }
            if (info == null && discover) {
                main.post { status.text = "Ищу компьютер в сети…" }
                Net.discover(pin)?.let { (b, i) -> base = b; info = i }
            }
            val found = info
            val foundBase = base
            main.post {
                connecting = false
                if (found != null && foundBase != null) {
                    if (foundBase != server) prefs.edit().putString("server", foundBase).apply()
                    server = foundBase
                    when (found.optString("error")) {
                        "pin" -> {
                            status.text = "Нужен PIN-код"
                            status.setTextColor(getColor(R.color.err))
                            askPin(wrong = pin.isNotEmpty())
                        }
                        "locked" -> {
                            status.text = found.optString("message")
                            status.setTextColor(getColor(R.color.err))
                        }
                        else -> showInfo(found)
                    }
                } else {
                    val mine = Net.ownAddresses()
                    status.text = "Компьютер не найден. Он включён и PhonePrint запущен? Адрес — в ⚙" + when {
                        mine.isEmpty() -> "\nТелефон не подключён к Wi-Fi."
                        else -> "\nТелефон в сети ${mine.joinToString()} — адрес ПК должен начинаться так же (первые три числа)."
                    }
                    status.setTextColor(getColor(R.color.err))
                }
            }
        }.start()
    }

    private fun showInfo(info: JSONObject) {
        val target = info.optString("printer")
        val parts = mutableListOf(target)
        val st = info.optString("status")
        if (st.isNotEmpty() && st != "Normal") parts += st
        val q = info.optInt("queue")
        if (q > 0) parts += "в очереди: $q"
        if (info.optBoolean("dryRun")) parts += "пробный режим"
        status.text = parts.joinToString(" · ")
        status.setTextColor(getColor(R.color.muted))

        // Список принтеров. Первый пункт — «по умолчанию на ПК»: шлём пустое имя,
        // и компьютер сам берёт тот принтер, что сейчас выбран в Windows.
        val names = info.optJSONArray("printers")?.let { a -> List(a.length()) { a.optString(it) } }.orEmpty()
        val current = printerValues.getOrNull(printer.selectedItemPosition)
            ?: prefs.getString(KEY_PRINTER, "").orEmpty()
        printerValues = listOf("") + names
        val labels = listOf("По умолчанию на ПК ($target)") + names
        printer.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_item, labels).also {
            it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }
        printer.setSelection(printerValues.indexOf(current).coerceAtLeast(0))

        // Двусторонняя печать: галочка видна только у принтеров, чей драйвер её поддерживает
        defaultPrinterName = target
        duplexSupport = info.optJSONObject("duplex")?.let { d -> d.keys().asSequence().associateWith { d.optBoolean(it) } }.orEmpty()
        updateDuplexVisibility()

        // недавние задания
        history.removeAllViews()
        val h = info.optJSONArray("history")
        val count = h?.length() ?: 0
        historyTitle.visibility = if (count > 0) View.VISIBLE else View.GONE
        for (i in 0 until minOf(count, 15)) {
            val e = h!!.getJSONObject(i)
            val row = layoutInflater.inflate(R.layout.item_history, history, false)
            row.findViewById<TextView>(R.id.time).text = e.optString("time")
            row.findViewById<TextView>(R.id.name).text = e.optString("name")
            val ok = e.optBoolean("ok")
            row.findViewById<TextView>(R.id.mark).apply {
                text = if (ok) "✓" else "✕"
                setTextColor(getColor(if (ok) R.color.ok else R.color.err))
            }
            if (!ok) row.setOnClickListener { toast(e.optString("message")) }
            history.addView(row)
        }
    }

    private fun pinField(value: String = "") = EditText(this).apply {
        setText(value)
        hint = "PIN-код"
        inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
        transformationMethod = PasswordTransformationMethod.getInstance()
        isSingleLine = true
    }

    private fun savePin(value: String) {
        pin = value.trim()
        prefs.edit().putString("pin", pin).apply()
    }

    /** Просит PIN-код, который задан в меню значка PhonePrint на компьютере. */
    private fun askPin(wrong: Boolean) {
        if (pinDialog?.isShowing == true) return
        val input = pinField()
        pinDialog = AlertDialog.Builder(this)
            .setTitle("PIN-код")
            .setMessage(if (wrong) "Неверный PIN-код. Попробуйте ещё раз." else "Введите PIN-код, заданный на компьютере (меню значка PhonePrint в трее).")
            .setView(padded(input))
            .setPositiveButton("Войти") { _, _ ->
                savePin(input.text.toString())
                refresh(discover = false)
            }
            .setNegativeButton("Отмена", null)
            .show()
    }

    /** Имя принтера на ПК, на который сейчас уйдёт печать ("" в списке = принтер по умолчанию). */
    private fun selectedPrinterName(): String =
        printerValues.getOrNull(printer.selectedItemPosition).orEmpty().ifEmpty { defaultPrinterName }

    private fun duplexAvailable() = duplexSupport[selectedPrinterName()] == true

    private fun updateDuplexVisibility() {
        duplexBox.visibility = if (duplexAvailable()) View.VISIBLE else View.GONE
    }

    private fun showSettings() {
        val input = EditText(this).apply {
            setText(server?.removePrefix("http://").orEmpty())
            hint = "192.168.1.50:8080"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            isSingleLine = true
        }
        val pinInput = pinField(pin)
        val form = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(input)
            addView(pinInput)
        }
        AlertDialog.Builder(this)
            .setTitle("Компьютер")
            .setMessage("Адрес обычно находится сам — он виден в меню значка PhonePrint в трее. PIN-код нужен, если вы задали его на компьютере.")
            .setView(padded(form))
            .setPositiveButton("Сохранить") { _, _ ->
                savePin(pinInput.text.toString())
                val t = input.text.toString().trim().removePrefix("http://").trimEnd('/')
                if (t.isNotEmpty()) {
                    server = "http://" + if (t.contains(':')) t else "$t:${Net.PORT}"
                    prefs.edit().putString("server", server).apply()
                }
                refresh(discover = server == null)
            }
            .setNeutralButton("Найти") { _, _ ->
                savePin(pinInput.text.toString())
                server = null
                refresh(discover = true)
            }
            .setNegativeButton("Отмена", null)
            .show()
    }

    // ---------- печать ----------

    private fun setCopies(n: Int) {
        copies = n.coerceIn(1, 50)
        copiesView.text = copies.toString()
    }

    private fun startPrint() {
        if (busy) return
        val pagesText = pages.text.toString().replace(" ", "")
        if (pagesText.isNotEmpty() && !PAGES_RE.matches(pagesText)) {
            toast("Страницы: например 1-3,5")
            return
        }
        val base = server
        if (base == null) {
            toast("Компьютер ещё не найден")
            refresh(discover = true)
            return
        }
        val printerName = printerValues.getOrNull(printer.selectedItemPosition).orEmpty()
        prefs.edit().putString(KEY_PRINTER, printerName).apply()
        val n = copies
        val useDuplex = duplexAvailable() && duplex.isChecked
        val todo = items.filter { it.state == PrintItem.State.WAIT || it.state == PrintItem.State.ERROR }
        if (todo.isEmpty()) return

        busy = true
        render()
        worker.execute {
            for (item in todo) {
                main.post { item.state = PrintItem.State.UPLOAD; item.progress = 0f; render() }
                val (ok, msg) = try {
                    Net.upload(contentResolver, base, item, n, pagesText, printerName, useDuplex, pin,
                        onProgress = { p -> main.post { item.progress = p; renderThrottled() } },
                        onSent = { main.post { item.state = PrintItem.State.PRINTING; render() } })
                } catch (e: Exception) {
                    false to friendly(e)
                }
                main.post {
                    item.state = if (ok) PrintItem.State.DONE else PrintItem.State.ERROR
                    item.message = msg.ifEmpty { if (ok) "Готово" else "Ошибка" }
                    render()
                }
            }
            main.post {
                busy = false
                render()
                refresh(discover = false)
            }
        }
    }

    private fun friendly(e: Exception): String = when (e) {
        is ConnectException, is UnknownHostException -> "Нет связи с компьютером. Он включён и в той же Wi-Fi сети?"
        is SocketTimeoutException -> "Компьютер не ответил вовремя"
        else -> e.message ?: e.javaClass.simpleName
    }

    // ---------- отрисовка ----------

    private fun renderThrottled() {
        val now = SystemClock.uptimeMillis()
        if (now - lastRender > 120) render()
    }

    private fun render() {
        lastRender = SystemClock.uptimeMillis()
        queue.removeAllViews()
        items.forEachIndexed { index, it -> queue.addView(itemView(it, index)) }
        val todo = items.any { it.state == PrintItem.State.WAIT || it.state == PrintItem.State.ERROR }
        btnPrint.isEnabled = !busy && todo
        btnPrint.alpha = if (btnPrint.isEnabled) 1f else 0.45f
        btnPrint.text = if (busy) "Печатается…" else "Печать"
    }

    private fun itemView(it: PrintItem, index: Int): View {
        val row = layoutInflater.inflate(R.layout.item_file, queue, false)
        row.findViewById<TextView>(R.id.name).text = it.name
        val st = row.findViewById<TextView>(R.id.state)
        val bar = row.findViewById<ProgressBar>(R.id.bar)
        val remove = row.findViewById<ImageButton>(R.id.remove)
        when (it.state) {
            PrintItem.State.WAIT -> st.text = formatSize(it.size)
            PrintItem.State.UPLOAD -> {
                st.text = "Отправка ${(it.progress * 100).toInt()}%"
                bar.visibility = View.VISIBLE
                bar.progress = (it.progress * 1000).toInt()
            }
            PrintItem.State.PRINTING -> st.text = "Печатается…"
            PrintItem.State.DONE -> {
                st.text = "✓ ${it.message}"
                st.setTextColor(getColor(R.color.ok))
            }
            PrintItem.State.ERROR -> {
                st.text = "✕ ${it.message}"
                st.setTextColor(getColor(R.color.err))
            }
        }
        val removable = !busy && it.state != PrintItem.State.UPLOAD && it.state != PrintItem.State.PRINTING
        remove.visibility = if (removable) View.VISIBLE else View.INVISIBLE
        remove.setOnClickListener {
            items.removeAt(index)
            render()
        }
        return row
    }

    private fun formatSize(n: Long): String = when {
        n < 0 -> ""
        n < 1024 -> "$n Б"
        n < 1024 * 1024 -> "${n / 1024} КБ"
        else -> String.format(Locale.ROOT, "%.1f МБ", n / 1048576.0)
    }

    private fun padded(v: View): View = FrameLayout(this).apply {
        val p = (20 * resources.displayMetrics.density).toInt()
        setPadding(p, p / 2, p, 0)
        addView(v)
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_LONG).show()
}
