import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.Commons
import "Anki.js" as Anki

// The study session: owns the deck, the scheduling progress, and the queue,
// and knows nothing about what is hosting it. The panel mounts one of these
// and drives it with reveal()/answer(); everything else lives here.
Item {
  id: root

  // Absolute path to the deck the user authors, and the directory the
  // scheduling progress is written to.
  property string deckPath: ""
  property string stateDir: ""

  readonly property string home: Quickshell.env("HOME")

  // Both files must sit inside the home directory: the helpers walk the chain
  // component by component and refuse symlinks, and a path outside home cannot
  // be walked that way. Empty means refused, and no process is started for it.
  readonly property string deckRel: Anki.relativeToHome(root.deckPath, root.home)
  readonly property string progressRel:
      Anki.relativeToHome(root.stateDir + "/omanki.json", root.home)

  // Where media filenames on a card resolve to. Same containment rule as the
  // deck and progress files: outside home, nothing in it is trusted.
  readonly property string mediaDir: Anki.mediaDirFor(root.deckPath)
  readonly property string mediaRel: Anki.relativeToHome(root.mediaDir, root.home)
  property int newPerDay: 20
  // 0 means no cap. A limit you have not set should not be a limit of nothing.
  property int reviewsPerDay: 0

  // How many times a card may be forgotten before it is treated as a leech.
  // 0 turns leeches off. `leechSuspend` decides whether reaching it takes the
  // card out of the rotation or only marks it.
  property int leechThreshold: Anki.LEECH_THRESHOLD
  property bool leechSuspend: true

  // How much of a lapsed card's interval survives the lapse, as a percentage.
  // Anki's own default is 0; see LAPSE_PERCENT for why this one differs.
  property int lapsePercent: Anki.LAPSE_PERCENT

  // Everything a grade depends on beyond the card itself. Named for what it is
  // rather than for the leeches it used to be, now that it carries the lapse
  // share too.
  readonly property var gradeOpts: ({
    lapsePercent: root.lapsePercent,
    leechThreshold: root.leechThreshold,
    leechSuspend: root.leechSuspend
  })

  // Restrict the session to cards carrying any of these tags. Empty means the
  // whole deck.
  property var tags: []

  // False whenever the panel is closed, so a session neither ticks nor holds
  // a card revealed while nobody is looking at it.
  property bool active: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  // How big the card reads and how much room it holds are the host's call, the
  // way a game board lets its host pick the cell size. The bar panel is a popup
  // and sizes to its text; the fullscreen overlay is a study surface and wants a
  // fixed, larger face that does not jump as answers change length.
  property int minFaceHeight: 0
  property real questionFontSize: Style.font.heading
  property real answerFontSize: Style.font.subtitle

  // ----------------------------------------------------------------- state
  property var deck: []
  readonly property var cards: Anki.filterByTags(root.deck, root.tags)
  property var progress: Anki.emptyProgress()
  property var queue: []
  property string deckError: ""
  property bool loaded: false

  // Answered in this sitting, which is the only number that tells you whether
  // the session did anything — the due count moves for other reasons.
  property int answered: 0

  property bool revealed: false

  // Answers taken back, newest last. In memory and per sitting: undo is for
  // the grade you just fumbled, not a history you carry between sessions, and
  // a snapshot from an hour ago could no longer be true after the other
  // surface has been answering the same deck.
  property var undoStack: []
  readonly property bool canUndo: root.undoStack.length > 0

  // Set by undo so the next rebuild puts that card back in front of you.
  property string pinned: ""

  // Re-derived on every tick as well as on every answer, so a card that comes
  // due mid-session appears without the user doing anything.
  property var stats: Anki.counts(root.cards, root.progress, root.now, root.newPerDay, root.reviewsPerDay)

  property int now: Math.floor(Date.now() / 1000)

  readonly property string currentId: root.queue.length ? root.queue[0] : ""
  readonly property var current: root.cardById(root.currentId)
  readonly property var currentState: Anki.stateFor(root.progress, root.currentId)

  // loading | error | empty | reviewing | waiting | done
  readonly property string phase: {
    if (!root.loaded) return "loading"
    if (root.deckError) return "error"
    if (root.current) return "reviewing"
    if (!root.cards.length) return "empty"
    if (root.stats.waiting > 0) return "waiting"
    return "done"
  }

  // Re-evaluated as `now` ticks, so an idle session counts down rather than
  // showing whatever the gap was when the last card was answered.
  readonly property string untilNext:
      root.stats.nextDue ? Anki.formatInterval(root.stats.nextDue - root.now) : ""

  readonly property var preview: root.current
      ? Anki.previewIntervals(root.currentState, root.now)
      : ({ again: "", hard: "", good: "", easy: "" })

  // Recomputed whenever the deck, the progress, or the clock moves, which is
  // exactly when a statistic could have changed.
  readonly property var deckStats:
      Anki.deckStats(root.cards, root.progress, root.now, root.newPerDay, root.reviewsPerDay)

  // The full year, flat and column-major (see Anki.heatmapGrid) — always
  // computed at its full width. A surface with room for fewer weeks takes as
  // many trailing columns (7 cells each) as it can show; slicing off the end
  // of a column-major array is exactly slicing off the most recent weeks.
  readonly property var heatmap: Anki.heatmapGrid(root.progress, root.now, Anki.HEATMAP_WEEKS)

  signal graded(string grade)
  signal cardAdded()

  // Empty unless the last attempt to add a card failed, in which case it says
  // why and the composer keeps what was typed.
  property string addError: ""
  property bool adding: false

  // Set when the last answer turned a card into a leech, and cleared a few
  // seconds later. A card that silently disappears from the rotation is the
  // one thing about leeches that would read as a bug rather than a decision,
  // so the surface says it happened at the moment it happens.
  property string leechNotice: ""

  Timer {
    id: leechNoticeTimer
    interval: 6000
    onTriggered: root.leechNotice = ""
  }

  Component.onCompleted: root.reload()

  // Coming back is the moment to pick up deck edits made while the panel was
  // closed, and to drop a card that was left face-up in the last session.
  onActiveChanged: {
    if (root.active) {
      root.revealed = false
      root.answered = 0
      root.undoStack = []
      root.reload()
    }
  }

  onDeckPathChanged: if (root.loaded) root.reload()
  onTagsChanged: if (root.loaded) root.rebuild()

  function cardById(id) {
    if (!id) return null
    for (var i = 0; i < root.cards.length; i++)
      if (root.cards[i].id === id) return root.cards[i]
    return null
  }

  // ------------------------------------------------------------- the session
  function refresh() {
    root.now = Math.floor(Date.now() / 1000)
    root.stats = Anki.counts(root.cards, root.progress, root.now, root.newPerDay, root.reviewsPerDay)
  }

  function rebuild() {
    root.refresh()
    var queue = Anki.buildQueue(root.cards, root.progress, root.now, root.newPerDay, root.reviewsPerDay)

    // Only pin a card the session can actually show: a filter change could
    // have removed it, and a queue holding an id with no card behind it would
    // leave the surface with nothing to render.
    if (root.pinned) {
      if (root.cardById(root.pinned)) queue = Anki.promote(queue, root.pinned)
      root.pinned = ""
    }

    root.queue = queue
    root.revealed = false
  }

  function reveal() {
    if (root.phase === "reviewing") root.revealed = true
  }

  // Front audio plays once a new card is on screen; back audio, once the
  // answer is revealed. Neither is forced on the user beyond that first play:
  // `p` calls this again for whichever face is currently showing.
  onCurrentChanged: {
    frontPlayer.stop()
    backPlayer.stop()
    if (root.current && root.current.frontAudioPath) frontPlayer.play()
  }

  onRevealedChanged: {
    if (root.revealed && root.current && root.current.backAudioPath) backPlayer.play()
  }

  function replayAudio() {
    if (root.revealed && root.current && root.current.backAudioPath) backPlayer.play()
    else if (root.current && root.current.frontAudioPath) frontPlayer.play()
  }

  MediaPlayer {
    id: frontPlayer
    audioOutput: AudioOutput {}
    source: root.current && root.current.frontAudioPath ? "file://" + root.current.frontAudioPath : ""
  }

  MediaPlayer {
    id: backPlayer
    audioOutput: AudioOutput {}
    source: root.current && root.current.backAudioPath ? "file://" + root.current.backAudioPath : ""
  }

  // Space and Enter mean "show me the answer", then "I knew it" — the same two
  // presses Anki trains into your hands.
  function activate() {
    if (root.revealed) root.answer("good")
    else root.reveal()
  }

  function answer(g) {
    if (root.phase !== "reviewing" || !root.revealed) return

    var id = root.currentId
    var before = Anki.stateFor(root.progress, id)
    // The roll is drawn here rather than inside the scheduler, so that the
    // interval spreads once — at the moment the answer is committed — and the
    // priced labels above, which grade the same card without a roll, keep
    // showing a number that does not move while you decide.
    var after = Anki.grade(before, g, root.now, Math.random(), root.gradeOpts)

    // Only on the answer that makes one. A card already marked stays marked,
    // and re-answering it must not announce the same thing again.
    if (after.leech && !before.leech) {
      root.leechNotice = after.suspended
          ? "Leech — suspended after " + after.lapses + " lapses"
          : "Leech — forgotten " + after.lapses + " times"
      leechNoticeTimer.restart()
    }

    // Copied rather than mutated in place: `progress` is a var property, and
    // QML only re-evaluates the bindings that depend on it when the reference
    // itself changes.
    var reviews = {}
    for (var key in root.progress.reviews) reviews[key] = root.progress.reviews[key]

    // Snapshot before the write. `had` separates a card with no history at all
    // from one whose history merely looks new, so taking back a card's first
    // answer removes its entry instead of leaving a zeroed one behind — which
    // would otherwise count against the day's new-card allowance forever.
    root.undoStack = root.undoStack.concat([{
      id: id,
      had: Object.prototype.hasOwnProperty.call(reviews, id),
      before: before
    }]).slice(-Anki.UNDO_DEPTH)

    reviews[id] = after
    root.progress = { reviews: reviews, activity: root.progress.activity }

    root.answered++
    root.save()
    root.rebuild()
    root.graded(g)
  }

  // Put every suspended card back in the rotation. The leech mark itself is
  // kept — the card has been trouble and the statistics should go on saying
  // so — so a restored card that keeps lapsing is raised again at the next
  // half-threshold rather than immediately.
  //
  // Returns how many came back, so the caller can say so rather than leaving
  // the user to guess whether anything happened.
  function restoreLeeches() {
    var result = Anki.unsuspendAll(root.progress, root.now)
    if (!result.restored) return 0

    root.progress = result.progress
    root.save()
    root.rebuild()
    return result.restored
  }

  // Take back the last answer. The card returns to exactly the state it was in
  // before, and comes back revealed and in front of you — you undid because
  // the grade was wrong, so the next keystroke should be able to be the right
  // one.
  function undo() {
    if (!root.undoStack.length) return

    var stack = root.undoStack.slice()
    var last = stack.pop()
    root.undoStack = stack

    var reviews = {}
    for (var key in root.progress.reviews) reviews[key] = root.progress.reviews[key]

    // Restored with a fresh stamp, and written rather than deleted. A merge
    // resolves per card by which entry is newer, so an older restored state
    // would lose to the answer it is undoing, and an outright deletion would
    // simply be re-added from the other surface's copy. A card that had no
    // history goes back as an untouched new one, which counts as new
    // everywhere it matters.
    var restored = Anki.normalizeState(last.had ? last.before : null)
    restored.updated = root.now
    reviews[last.id] = restored

    root.progress = { reviews: reviews, activity: root.progress.activity }
    root.answered = Math.max(0, root.answered - 1)
    root.save()

    // Undoing the lapse that made a leech takes the mark back with it, since
    // the whole prior state is restored — so a notice still on screen would be
    // describing something that no longer happened.
    root.leechNotice = ""
    leechNoticeTimer.stop()

    root.pinned = last.id
    root.rebuild()
    // After the rebuild, which clears it.
    root.revealed = true
  }

  // --------------------------------------------------------------- loading
  // A path the helpers will refuse is caught here, before any process runs, so
  // the surface can say what is wrong instead of showing an empty deck.
  function checkPaths() {
    if (!root.deckRel) {
      root.deckError = "Deck must be inside your home directory"
      return false
    }
    root.deckError = ""
    return true
  }

  function reload() {
    // Cleared first so a rebuild waits for both files again. A reader already
    // in flight still sets its own flag when it finishes, so nothing is lost
    // by not restarting it.
    root.deckRead = false
    root.progressRead = false
    root.mediaRead = false
    if (!root.checkPaths()) {
      root.deck = []
      root.deckRead = true
      root.progressRead = true
      root.mediaRead = true
      root.loaded = true
      root.rebuild()
      return
    }
    if (!deckReader.running) deckReader.running = true
    if (!progressReader.running) progressReader.running = true
  }

  property bool deckRead: false
  property bool progressRead: false
  property bool mediaRead: false
  property var mediaFilenames: []

  // The queue needs all three: both files, and — only when the deck actually
  // references any — the media validation pass. They finish in whichever
  // order they finish, so building it waits for the lot.
  function readFinished() {
    if (!root.deckRead || !root.progressRead || !root.mediaRead) return
    root.loaded = true
    root.rebuild()
  }

  Process {
    id: deckReader
    command: ["sh", "-c", Anki.READ_SH, "omanki-deck", root.home, root.deckRel]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // An absent deck is the first-run state, not an error; a deck that
        // exists but does not parse is one the user needs told about.
        if (!text.trim()) {
          root.deck = []
          if (!root.deckError) root.deckError = ""
        } else {
          var parsed = Anki.parseDeck(text)
          root.deck = parsed.cards
          root.deckError = parsed.error
        }
        root.deckRead = true

        // Only spun up when the deck actually points at media, and only when
        // there is somewhere safe to look for it — the same file this deck
        // came from could sit outside home in a broken config, and refusing
        // that path is checkPaths' job, not this one's.
        var names = Anki.collectMediaFilenames(root.deck)
        if (!names.length || !root.mediaRel) {
          root.mediaRead = true
        } else {
          root.mediaFilenames = names
          // Reopened for every run, the same reason writer/merger do: a
          // Process keeps stdinEnabled across runs, and onStarted below turns
          // it off to signal EOF — without resetting it here, every reload
          // after the first starts this script with stdin already closed, so
          // it reads no filenames and every media path silently goes blank.
          mediaValidator.stdinEnabled = true
          mediaValidator.running = true
        }
        root.readFinished()
      }
    }
  }

  // One batched validation per deck load rather than one process per card per
  // render: every filename any card refers to is sent down at once, and the
  // answers come back matched to them by position. See MEDIA_VALIDATE_SH.
  Process {
    id: mediaValidator
    command: ["sh", "-c", Anki.MEDIA_VALIDATE_SH, "omanki-media", root.home, root.mediaRel]
    stdinEnabled: true
    onStarted: {
      var names = root.mediaFilenames
      write(names.length ? names.join("\n") + "\n" : "")
      stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.length ? text.split("\n") : []
        if (lines.length && lines[lines.length - 1] === "") lines.pop()

        var map = {}
        var names = root.mediaFilenames
        for (var i = 0; i < names.length && i < lines.length; i++) {
          if (lines[i]) map[names[i]] = lines[i]
        }

        root.deck = Anki.attachMediaPaths(root.deck, map)
        root.mediaRead = true
        root.readFinished()
      }
    }
  }

  Process {
    id: progressReader
    command: ["sh", "-c", Anki.READ_SH, "omanki-progress", root.home, root.progressRel]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Anki.parseProgress(text)
        var frozen = Anki.freezeActivity(parsed, root.now)
        root.progress = frozen
        root.progressRead = true

        // Only elapsed days get frozen, so this fires at most once per day —
        // every other load finds nothing new and this is a no-op. See
        // freezeActivity for why it has to run here, at load, rather than
        // waiting for the next answer to save it incidentally.
        if (Object.keys(frozen.activity).length > Object.keys(parsed.activity).length) root.save()

        root.readFinished()
      }
    }
  }

  // ---------------------------------------------------------------- saving
  //
  // Every save is read-merge-write, never a blind overwrite. Both surfaces can
  // be on screen at once, each holding its own copy of the document, and
  // neither reloads while it is being used — so a surface writing what it
  // remembers erases whatever the other one did in the meantime. Merging on
  // the way out costs one small read per answer and makes the two independent.
  //
  // The read closes the window to the few milliseconds between it and the
  // rename, which no human answering cards can hit; the alternative, holding
  // the file open across the merge, would mean the shell holding a lock on a
  // file the user may want to delete.
  //
  // One writer at a time. Each document is complete, so a save landing
  // mid-write waits and supersedes whatever was queued behind it.
  property bool saveQueued: false

  function save() {
    root.saveQueued = true
    root.flushSave()
  }

  function flushSave() {
    if (!root.saveQueued || writer.running || merger.running) return
    root.saveQueued = false
    merger.running = true
  }

  // Reads what is on disk right now, folds this surface's state into it, and
  // hands the result to the writer.
  Process {
    id: merger
    command: ["sh", "-c", Anki.READ_SH, "omanki-merge", root.home, root.progressRel]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var merged = Anki.mergeProgress(root.progress, Anki.parseProgress(text))

        // Adopt the merged document, so the next answer builds on the other
        // surface's work rather than on a copy that is already behind. The
        // queue is left alone: it is rebuilt on the next answer anyway, and
        // rearranging cards under someone mid-session would be worse than a
        // slightly stale order.
        root.progress = merged

        writer.document = Anki.serializeProgress(merged)
        // Reopened for every write. Closing stdin is how the document is
        // terminated (see below), and a Process keeps that setting, so without
        // this the second save of a session starts a `cat` that blocks forever
        // on a stdin nobody will write to — leaving `running` true and
        // silently dropping every save after the first.
        writer.stdinEnabled = true
        writer.running = true
      }
    }
  }

  Process {
    id: writer
    property string document: ""
    command: ["sh", "-c", Anki.WRITE_SH, "omanki-write", root.home, root.progressRel]
    stdinEnabled: true
    onStarted: {
      write(document)
      document = ""
      // Closing stdin is what tells `cat` the document is finished; without
      // it the write never completes and the next save never starts.
      // flushSave reopens it before each run.
      stdinEnabled = false
    }
    onExited: root.flushSave()
  }

  // ------------------------------------------------------------ adding cards
  //
  // The deck belongs to the user, so this is read-modify-write over its actual
  // text rather than a regeneration from what the session parsed: their
  // formatting is lost to a reserialize, but their cards, their field order,
  // and any field this plugin knows nothing about are not.
  property var pendingCard: null

  // Every refusal goes through here. A refused add is shown in the composer and
  // then forgotten, which leaves nothing behind for a test to look at: from
  // outside, a card correctly refused and an add that quietly did nothing are
  // the same event - the deck simply did not change. That ambiguity is not
  // hypothetical. The soak's two refusal assertions are both of the form "the
  // file did not change", and they sat green through a whole session in which
  // adds were going to a different file entirely.
  //
  // So the reason is written to the log as well as to the screen. It is also
  // the only trace a user has after the composer clears.
  //
  // The reason only, never the card: these strings are fixed messages from
  // appendCard, and a front typed into a flashcard has no business in the
  // journal.
  function refuseAdd(reason) {
    root.addError = reason
    root.adding = false
    console.log("omanki: add refused: " + reason)
  }

  function addCard(front, back, tags) {
    if (root.adding) return
    root.addError = ""
    root.adding = true
    root.pendingCard = { front: front, back: back, tags: tags }
    deckEditReader.running = true
  }

  Process {
    id: deckEditReader
    command: ["sh", "-c", Anki.READ_SH, "omanki-deck-edit", root.home, root.deckRel]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var card = root.pendingCard
        root.pendingCard = null
        if (!card) { root.adding = false; return }

        var result = Anki.appendCard(text, card.front, card.back, card.tags)
        if (result.error) {
          root.refuseAdd(result.error)
          return
        }

        deckWriter.document = result.raw
        deckWriter.stdinEnabled = true
        deckWriter.running = true
      }
    }
  }

  Process {
    id: deckWriter
    property string document: ""
    command: ["sh", "-c", Anki.WRITE_SH, "omanki-deck-write", root.home, root.deckRel]
    stdinEnabled: true
    onStarted: {
      write(document)
      document = ""
      stdinEnabled = false
    }
    onExited: function(code) {
      root.adding = false
      if (code !== 0) {
        root.refuseAdd("Could not write the deck (" + code + ")")
        return
      }
      // Re-read so the new card joins the session it was written for.
      root.reload()
      root.cardAdded()
    }
  }

  // Two cadences from one timer.
  //
  // On screen it ticks every second, so a learning card due in a minute
  // arrives on its own without the user doing anything.
  //
  // Off screen it ticks slowly and re-reads both files, which is what keeps
  // the bar's count honest. Cards come due on a clock nobody is watching, and
  // the other surface writes progress this one has never seen — without this
  // the count would freeze at whatever it was when the surface last closed.
  Timer {
    interval: root.active ? 1000 : 60000
    running: root.loaded
    repeat: true
    onTriggered: {
      if (!root.active) {
        root.reload()
        return
      }

      var was = root.queue.length
      root.refresh()
      // Only rebuild when something actually became available — rebuilding
      // every second would reset the card under the user's hands.
      if (!was && root.stats.pending > 0) root.rebuild()
    }
  }

  // ---------------------------------------------------------------- render
  implicitHeight: content.implicitHeight

  Column {
    id: content
    width: parent.width
    spacing: Style.spacing.md

    // ------------------------------------------------------- the card face
    Rectangle {
      width: parent.width
      visible: root.phase === "reviewing"
      implicitHeight: Math.max(root.minFaceHeight, face.implicitHeight + Style.spacing.lg * 2)
      color: Util.alpha(root.foreground, 0.05)
      radius: Style.cornerRadius
      border.width: Math.max(1, Style.space(1))
      border.color: Util.alpha(root.foreground, 0.12)

      Column {
        id: face
        anchors.centerIn: parent
        width: parent.width - Style.spacing.lg * 2
        spacing: Style.spacing.md

        Image {
          width: parent.width
          height: Math.min(implicitHeight, Style.space(240))
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          visible: !!(root.current && root.current.frontImagePath)
          source: root.current && root.current.frontImagePath ? "file://" + root.current.frontImagePath : ""
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: root.current ? root.current.front : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.questionFontSize
        }

        // The separator only appears with the answer, so the face of an
        // unrevealed card is the question and nothing else.
        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          visible: root.revealed
          color: Util.alpha(root.foreground, 0.15)
        }

        Image {
          width: parent.width
          height: Math.min(implicitHeight, Style.space(240))
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          visible: root.revealed && !!(root.current && root.current.backImagePath)
          source: root.revealed && root.current && root.current.backImagePath ? "file://" + root.current.backImagePath : ""
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.revealed
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          text: root.current ? root.current.back : ""
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: root.answerFontSize
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: !root.revealed
          horizontalAlignment: Text.AlignHCenter
          text: "space to reveal"
          color: root.foreground
          opacity: 0.35
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // The only sign a face has audio at all: a clip that autoplays and
      // finishes in under a second leaves nothing else to notice it by.
      // Doubles as a replay button, the mouse's equivalent of `p`. Anchored
      // to the card's own corners rather than sitting in the text column, so
      // it reads as a badge on the card and not as another line of content.
      Text {
        textFormat: Text.PlainText
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Style.spacing.md
        visible: !!(root.current && root.current.frontAudioPath)
        text: "󰕾"
        color: root.foreground
        opacity: 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle

        MouseArea {
          anchors.fill: parent
          anchors.margins: Style.space(-6)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.replayAudio()
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.margins: Style.spacing.md
        visible: root.revealed && !!(root.current && root.current.backAudioPath)
        text: "󰕾"
        color: root.accent
        opacity: 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle

        MouseArea {
          anchors.fill: parent
          anchors.margins: Style.space(-6)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.replayAudio()
        }
      }
    }

    // --------------------------------------------------------- other states
    Text {
      textFormat: Text.PlainText
      width: parent.width
      visible: root.phase !== "reviewing"
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      topPadding: Style.spacing.lg
      bottomPadding: Style.spacing.lg
      color: root.phase === "error" ? root.urgent : root.foreground
      opacity: root.phase === "error" ? 1.0 : 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      text: {
        if (root.phase === "loading") return "Loading deck…"
        if (root.phase === "error") return root.deckError + "\n" + root.deckPath

        // An empty session means one of two different things, and sending
        // someone to edit a deck that is actually full would be a wild goose
        // chase.
        //
        // A deck ships with the plugin, but copying it is a manual step, so
        // this is the screen a fresh install lands on. Naming the file here
        // saves going back to the README to learn it exists.
        if (root.phase === "empty") {
          return root.deck.length
              ? "No cards match #" + Anki.normalizeTags(root.tags).join(" #") + ".\n"
                + root.deck.length + " card" + (root.deck.length === 1 ? "" : "s") + " in the deck."
              : "No cards yet.\nAdd some to " + root.deckPath
                + "\nor copy cards.example.json from the plugin folder."
        }

        if (root.phase === "waiting") return "Nothing due right now.\n"
            + root.stats.waiting + " card" + (root.stats.waiting === 1 ? "" : "s")
            + " still learning — next in " + root.untilNext + "."

        var done = root.answered > 0
            ? "Done for now — " + root.answered + " reviewed."
            : "Nothing due."
        return root.stats.nextDue ? done + "\nNext card in " + root.untilNext + "." : done
      }
    }
  }
}
