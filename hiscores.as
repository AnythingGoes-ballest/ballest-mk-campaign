// Online hiscores for the cup's courses (part of MK Mushroom Cup; private, never publish). The plugin's own server
// (repo ballest-mk-hiscores: a Cloudflare Worker + D1) keeps each player's best time and splits per course; the
// game's Steam leaderboards are never touched (the courses are the player's own unpublished maps: they have none).
//
//   * Who you are: your Steam ID (Steam::OwnId) proven to the server with a Steam Web API ticket
//     (Steam::RequestWebTicket(kIdentity)), swapped for a 24 h session token (POST /session). A sandboxed test copy
//     can't make tickets (the sandbox blocks them) and its requests carry X-Ballest-Sandbox: 1 (the host adds it), so
//     there the server opens a test session from the Steam ID alone and everything goes to its test table.
//   * A finish on a course is sent (POST /submit) only if the host says the run is clean for this plugin's own
//     records (Race::RunTainted: practice, test commands, the ball moved or frozen, slow motion, another plugin's
//     pushes); this plugin's own mushroom bounce doesn't count against it. Runs that fail to send are kept and retried.
//   * The in-race leaderboard shows the online top 10 and your own place in place of the game's (empty) board
//     (Leaderboard::SetSource for the course's track key); the landing page shows the record and your place per course.
//   * Ghosts: a run that beats your online best is sent with its replay (the host's own recording of the run,
//     Runs::Replay: the game writes no ghost file for a local map, measured), kept with your best on the server.
//     Clicking a row of the in-race board races that player's best as the game's own leaderboard ghost (GET /replay,
//     then Leaderboard::SetRowGhost: the game's ghost, the row lit, the race restarted); clicking it again turns it off.
//     Clicking the row tile itself shows that run in the game's replay mode (Leaderboard::WatchRowReplay), with the
//     toggled ghosts too, as the game's own board does.
//   * Online splits: the checkpoint deltas under the race timer compare against your ONLINE best on the course
//     (Race::SetSplitReference), not the game's local record. Your online best's splits and time are kept in Storage
//     ("hiscores:best:<course>": "<total>|<split>,<split>,...") so they work offline and before /best answers;
//     fetched on sign-in and on each course, and replaced when a new online best is taken. No online best: no deltas.
// The local best (main.as, Storage) is kept as before: it works offline too.

const string kServer = "https://ballest-mk-hiscores.anythinggoes87654321.workers.dev";
const string kIdentity = "ballest-mk-hiscores";      // the server checks tickets with the same identity
const int kTopCount = 10;

class Board
{
    string track;                   // the course's name, the server's track key
    array<string> names;
    array<double> times;
    array<int> ranks;
    array<string> ids;              // Steam IDs, by row
    array<bool> hasReplay;
    int total = -1;                 // players on the board, -1 unknown
    int myRank = 0;
    double myTime = -1;
    bool myReplay = false;
    double fetchedAt = -1000;
    bool loaded = false;
}

class Job
{
    string kind;                    // "session", "top", "best", "submit"
    string track;
    string body;
    int id = 0;                     // > 0 under way, 0 waiting, -1 refused by the host
    int tries = 0;
    double wait = 0;                // not before this (Host::Time)
}

array<Board@> boards;
array<Job@> jobs;                   // waiting or under way, oldest first
string hsToken = "";
double hsTokenUntil = 0;
string hsSteamId = "";
string hsState = "";                // shown on the page when something is wrong
bool hsSessionStarting = false;
bool hsTicketAsked = false;
double hsTicketAt = 0;
double hsRetryAt = 0;
string hsShownKey = "";
// the ghost raced against: whose, on which course, its replay, its ball
string ghostTrack = "", ghostId = "", ghostName = "";
string watchTrack = "", watchId = "";       // a row tile clicked: that run in the game's replay mode, once downloaded
array<string> replayKeys;           // "<course>|<steam id>" of each replay downloaded this session
array<string> replayTexts;          // its JSON

void KeepReplay(const string &in key, const string &in text)
{
    int i = replayKeys.find(key);
    if (i >= 0) replayTexts[i] = text;
    else {
        replayKeys.insertLast(key);
        replayTexts.insertLast(text);
    }
}
array<string> shownIds;             // the Steam ID of each row on the board now (the clicked row's player)

Board@ BoardOf(const string &in track)
{
    for (uint i = 0; i < boards.length(); i++)
        if (boards[i].track == track) return boards[i];
    Board b;
    b.track = track;
    boards.insertLast(b);
    return b;
}

string UrlEncode(const string &in s)
{
    string encoded = "";
    for (uint i = 0; i < s.length(); i++) {
        uint8 c = s[i];
        if ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95 || c == 126) {
            string ch = " ";
            ch[0] = c;
            encoded += ch;
        } else {
            encoded += "%" + formatInt(c, "0H", 2);
        }
    }
    return encoded;
}

bool HaveSession() { return hsToken != "" && Host::Time() < hsTokenUntil - 60; }

void Enqueue(const string &in kind, const string &in track, const string &in body = "")
{
    for (uint i = 0; i < jobs.length(); i++)          // one of each read at a time
        if (kind != "submit" && jobs[i].kind == kind && jobs[i].track == track) return;
    Job j;
    j.kind = kind;
    j.track = track;
    j.body = body;
    jobs.insertLast(j);
}

// --- session -------------------------------------------------------------------------------------------------------

void StartSession()
{
    if (hsSessionStarting || Host::Time() < hsRetryAt) return;
    if (hsSteamId == "") hsSteamId = Steam::OwnId();
    if (hsSteamId == "") return;
    if (!hsTicketAsked) {
        hsTicketAsked = true;
        hsTicketAt = Host::Time();
        Steam::RequestWebTicket(kIdentity);
    }
    string state = Steam::WebTicketState();
    if (state == "pending") {
        if (Host::Time() - hsTicketAt > 20) hsTicketAsked = false;     // no answer from Steam: asked again
        return;
    }
    string body;
    if (state == "ready")
        body = "{\"ticket\":" + Json::Quote(Steam::WebTicket()) + "}";
    else
        body = "{\"steamid\":" + Json::Quote(hsSteamId) + "}";   // no ticket (a sandboxed test copy): a test session, if the server allows
    hsSessionStarting = true;
    Job j;
    j.kind = "session";
    j.body = body;
    jobs.insertAt(0, j);
}

// --- requests ------------------------------------------------------------------------------------------------------

int InFlight()
{
    int n = 0;
    for (uint i = 0; i < jobs.length(); i++)
        if (jobs[i].id > 0) n++;
    return n;
}

void Launch(Job@ j)
{
    if (j.kind == "session")
        j.id = Net::Post(kServer + "/session", j.body);
    else if (j.kind == "submit")
        j.id = Net::Post(kServer + "/submit", j.body, hsToken);
    else if (j.kind == "top")
        j.id = Net::Get(kServer + "/top?track=" + UrlEncode(j.track) + "&n=" + kTopCount);
    else if (j.kind == "best")
        j.id = Net::Get(kServer + "/best?track=" + UrlEncode(j.track) + "&steamid=" + hsSteamId);
    else if (j.kind == "replay")
        j.id = Net::Get(kServer + "/replay?track=" + UrlEncode(j.track) + "&steamid=" + j.body);
    if (j.id == 0) j.id = -1;       // refused (rate limit): tried again later
}

// A request answered: true to keep the job (to be tried again), false when it is done with.
bool Finished(Job@ j)
{
    int status = Net::Status(j.id);
    string body = Net::Body(j.id);
    string error = Net::Error(j.id);
    Net::Forget(j.id);
    j.id = 0;
    if (j.kind == "session") {
        hsSessionStarting = false;
        hsTicketAsked = false;
        if (status == 200 && Json::Bool(body, "ok")) {
            hsToken = Json::String(body, "token");
            hsTokenUntil = Host::Time() + 23 * 3600;
            hsState = "";
            Log::Info("hiscores: signed in as " + Json::String(body, "steamid") + (Json::Bool(body, "test") ? " (test session: the test board)" : ""));
        } else {
            hsState = "online hiscores: " + (status == 0 ? "can't reach the server (" + error + ")" : Json::String(body, "error", "sign-in failed (" + status + ")"));
            hsRetryAt = Host::Time() + 120;
            Log::Warn(hsState);
        }
        return false;
    }
    if (status == 0) {
        hsState = "online hiscores: can't reach the server (" + error + ")";
        return ++j.tries < 3 || j.kind == "submit";       // a run is kept until the server has answered it
    }
    if (j.kind == "submit") {
        if (status == 401) {                    // the session ran out: a new one, then this run again
            hsToken = "";
            return true;
        }
        if (status == 429 || status >= 500) return true;
        if (status == 200 && Json::Bool(body, "ok")) {
            Board@ b = BoardOf(j.track);
            b.myTime = Json::Number(body, "best") / 1000.0;
            b.myRank = int(Json::Number(body, "rank"));
            b.total = int(Json::Number(body, "total"));
            Log::Info("hiscores: " + j.track + " sent" + (Json::Bool(body, "improved") ? ", a new online best" : "") + ": #" + b.myRank + " of " + b.total +
                      (Json::Bool(body, "test") ? " (test board)" : ""));
            if (Json::Bool(body, "improved")) {
                array<double> splits;
                int n = Json::Count(j.body, "splits");
                for (int i = 0; i < n; i++) splits.insertLast(Json::Number(j.body, "splits." + i) / 1000.0);
                CacheBest(j.track, Json::Number(j.body, "timeMs") / 1000.0, splits);
            }
            Enqueue("top", j.track);
        } else {
            Log::Warn("hiscores: " + j.track + " run not taken: " + Json::String(body, "error", "HTTP " + status));
        }
        return false;
    }
    if (j.kind == "replay") {
        if (status == 200) KeepReplay(j.track + "|" + j.body, body);
        if (status == 200 && j.track == watchTrack && j.body == watchId) {
            Log::Info("hiscores: replay of " + j.body + " on " + j.track + " downloaded (" + body.length() + " bytes)");
            StartWatch();
        }
        if (status == 200 && j.track == ghostTrack && j.body == ghostId) {
            Log::Info("hiscores: ghost of " + ghostName + " on " + j.track + " downloaded (" + body.length() + " bytes)");
            StartGhost();
        } else if (status != 200) {
            Log::Warn("hiscores: no ghost for " + ghostName + ": " + Json::String(body, "error", "HTTP " + status));
            if (j.body == ghostId) ghostId = "";
        }
        return false;
    }
    Board@ b = BoardOf(j.track);
    if (status != 200) {
        hsState = "online hiscores: " + Json::String(body, "error", "HTTP " + status);
        return false;
    }
    if (j.kind == "top") {
        b.names.resize(0);
        b.times.resize(0);
        b.ranks.resize(0);
        b.ids.resize(0);
        b.hasReplay.resize(0);
        int n = Json::Count(body, "entries");
        for (int i = 0; i < n; i++) {
            string p = "entries." + i + ".";
            string name = Json::String(body, p + "name");
            string sid = Json::String(body, p + "steamid");
            if (name == "") name = Steam::PersonaName(sid);
            if (name == "") name = "player " + sid.substr(sid.length() - 4);
            b.names.insertLast(name);
            b.times.insertLast(Json::Number(body, p + "timeMs") / 1000.0);
            b.ranks.insertLast(int(Json::Number(body, p + "rank")));
            b.ids.insertLast(sid);
            b.hasReplay.insertLast(Json::Bool(body, p + "hasReplay"));
        }
        b.total = int(Json::Number(body, "total"));
        b.loaded = true;
        b.fetchedAt = Host::Time();
        if (hsSteamId == "") hsSteamId = Steam::OwnId();
        if (hsSteamId != "") Enqueue("best", j.track);
    } else if (j.kind == "best") {
        array<double> splits;
        if (Json::Has(body, "entry.rank")) {
            b.myRank = int(Json::Number(body, "entry.rank"));
            b.myTime = Json::Number(body, "entry.timeMs") / 1000.0;
            b.myReplay = Json::Bool(body, "entry.hasReplay");
            int n = Json::Count(body, "entry.splits");
            for (int i = 0; i < n; i++) splits.insertLast(Json::Number(body, "entry.splits." + i) / 1000.0);
            CacheBest(j.track, b.myTime, splits);
        } else {
            b.myRank = 0;
            b.myTime = -1;
            CacheBest(j.track, -1, splits);
        }
        b.total = int(Json::Number(body, "total"));
    }
    hsState = "";
    return false;
}

void PumpJobs()
{
    for (uint i = 0; i < jobs.length(); i++) {
        Job@ j = jobs[i];
        if (j.id > 0 && Net::Done(j.id)) {
            bool submit = j.kind == "submit";
            if (!Finished(j)) jobs.removeAt(jobs.findByRef(j));
            else j.wait = Host::Time() + 10;
            if (submit) SavePending();
            return;                 // the list may have changed
        }
    }
    if (InFlight() >= 3) return;
    for (uint i = 0; i < jobs.length(); i++) {
        Job@ j = jobs[i];
        if (j.id > 0 || Host::Time() < j.wait) continue;
        if (j.kind == "submit" && !HaveSession()) {
            StartSession();
            continue;
        }
        j.id = 0;
        Launch(j);
        if (j.id < 0) j.wait = Host::Time() + 5;     // refused by the host (its rate limit): later
        return;                     // one start a frame
    }
}

// Runs not sent yet survive a restart of the game (Storage, one line): "<track><tab><JSON body>" entries separated by "|".
void SavePending()
{
    string s = "";
    for (uint i = 0; i < jobs.length(); i++)
        if (jobs[i].kind == "submit") s += (s == "" ? "" : "|") + jobs[i].track + "\t" + jobs[i].body;
    Storage::Set("hiscores:pending", s);
}

void LoadPending()
{
    array<string>@ lines = Storage::Get("hiscores:pending", "").split("|");
    for (uint i = 0; i < lines.length(); i++) {
        int tab = lines[i].findFirst("\t");
        if (tab > 0) Enqueue("submit", lines[i].substr(0, tab), lines[i].substr(tab + 1));
    }
}

// --- online splits ----------------------------------------------------------------------------------------------------

string splitsShown = "<none>";       // the reference handed to the host now (its Storage text); never matches at first
string splitsTrack = "";

void CacheBest(const string &in track, double total, const array<double> &in splits)
{
    string s = formatFloat(total, "", 0, 3) + "|";
    for (uint i = 0; i < splits.length(); i++) s += (i > 0 ? "," : "") + formatFloat(splits[i], "", 0, 3);
    if (total <= 0) s = "";
    if (Storage::Get("hiscores:best:" + track, "") != s) {
        Storage::Set("hiscores:best:" + track, s);
        Log::Info("hiscores: online splits for " + track + (s == "" ? " cleared (no online best)" : " cached: " + s));
    }
}

// The cached online best of a course as the split reference while it is raced (an empty one: no deltas).
void FeedSplits(const string &in track)
{
    string s = Storage::Get("hiscores:best:" + track, "");
    if (Race::TrackKey() + "#" + s == splitsShown) return;     // (the key too: two courses can both have none)
    splitsShown = Race::TrackKey() + "#" + s;
    array<double> splits;
    double total = 0;
    int bar = s.findFirst("|");
    if (bar > 0) {
        total = parseFloat(s.substr(0, bar));
        array<string>@ parts = s.substr(bar + 1).split(",");
        for (uint i = 0; i < parts.length(); i++)
            if (parts[i] != "") splits.insertLast(parseFloat(parts[i]));
    }
    Race::SetSplitReference(Race::TrackKey(), splits, total);
}

// --- what main.as calls ----------------------------------------------------------------------------------------------

void HiscoresStart()
{
    LoadPending();
}

// A finish on a course (main.as TrackRace, the frame it is seen): sent unless the host says the run is touched.
void HiscoresFinished(const string &in track, double t, const array<double> &in splits)
{
    string why;
    if (Race::RunTainted(why)) {
        Log::Info("hiscores: " + track + " " + FormatTime(t) + " not sent: " + why);
        return;
    }
    string s = "[";
    for (uint i = 0; i < splits.length(); i++)
        s += (i > 0 ? "," : "") + int(splits[i] * 1000 + 0.5);
    s += "]";
    string body = "{\"track\":" + Json::Quote(track) + ",\"timeMs\":" + int(t * 1000 + 0.5) + ",\"splits\":" + s;
    // Its replay too when it beats the online best known here (the server keeps it only with a new best): the host's
    // recording of this run, the newest finished one on this track.
    Board@ b = BoardOf(track);
    if (b.myTime < 0 || t < b.myTime - 0.0005) {
        string replay = "";
        if (Runs::Count() > 0 && Runs::IsFinished(0) && Runs::TrackKey(0) == Race::TrackKey()) replay = Runs::Replay(0);
        if (replay.length() > 0 && replay.length() < 900000 && Json::Has(replay, "locations"))
            body += ",\"replay\":" + replay;
        else
            Log::Warn("hiscores: " + track + ": no replay of this run to send");
    }
    body += "}";
    Enqueue("submit", track, body);
    SavePending();
}

// Every frame (main.as Update): requests, and the in-race board for the course on track (-1: none).
void HiscoresUpdate(int course, const string &in track)
{
    PumpJobs();
    if (course >= 0) {
        Board@ b = BoardOf(track);
        if (track != splitsTrack) {             // a course raced: its online best fetched now (the cache serves till then)
            splitsTrack = track;
            if (hsSteamId == "") hsSteamId = Steam::OwnId();
            if (hsSteamId != "") Enqueue("best", track);
        }
        FeedSplits(track);
        if (Host::Time() - b.fetchedAt > 30) {
            b.fetchedAt = Host::Time();
            Enqueue("top", track);
        }
        // as the game's own board: the ghost toggle races that ghost, the row tile shows its run in replay mode
        int row = Leaderboard::ExtraRowGhostClicked();
        if (row >= 0 && row < int(shownIds.length())) PickGhost(track, row, b);
        row = Leaderboard::ExtraRowClicked();
        if (row >= 0 && row < int(shownIds.length())) WatchRow(track, row, b);
        ShowBoard(b);
    } else {
        if (hsShownKey != "") {
            Leaderboard::ClearSource();
            hsShownKey = "";
        }
        ghostId = "";                           // (the host gives the board back and the game's ghost goes with the map)
        if (splitsShown != "<none>") {
            Race::ClearSplitReference();
            splitsShown = "<none>";
        }
        splitsTrack = "";
    }
}

// A row clicked: that player's ghost, as the game's own leaderboard ghost (Leaderboard::SetRowGhost: the game's
// ghost, the row lit, the race restarted); the same row again: off (and restarted), as the game's own toggle does.
void PickGhost(const string &in track, int row, Board@ b)
{
    string id = shownIds[row];
    if (id != "" && id == Leaderboard::RowGhost()) {
        Log::Info("hiscores: ghost off");
        ghostId = "";
        Leaderboard::ClearRowGhost();
        return;
    }
    int i = b.ids.find(id);
    bool has = i >= 0 ? b.hasReplay[i] : (id == hsSteamId && b.myReplay);
    if (!has) {
        Log::Info("hiscores: no ghost saved for that run");
        return;
    }
    ghostTrack = track;
    ghostId = id;
    ghostName = i >= 0 ? b.names[i] : "you";
    if (replayKeys.find(track + "|" + id) >= 0) StartGhost();
    else Enqueue("replay", track, id);
    Log::Info("hiscores: racing the ghost of " + ghostName);
}

// A row tile clicked: that player's run in the game's replay mode (Leaderboard::WatchRowReplay), with every ghost
// toggled on still showing; the game's own exit returns to the race.
void WatchRow(const string &in track, int row, Board@ b)
{
    string id = shownIds[row];
    int i = b.ids.find(id);
    bool has = i >= 0 ? b.hasReplay[i] : (id == hsSteamId && b.myReplay);
    if (!has) {
        Log::Info("hiscores: no replay saved for that run");
        return;
    }
    watchTrack = track;
    watchId = id;
    Log::Info("hiscores: watching the replay of " + (i >= 0 ? b.names[i] : "you"));
    if (replayKeys.find(track + "|" + id) >= 0) StartWatch();
    else Enqueue("replay", track, id);
}

void StartWatch()
{
    int k = replayKeys.find(watchTrack + "|" + watchId);
    if (watchId == "" || k < 0) return;
    string id = watchId;
    watchId = "";
    int row = shownIds.find(id);
    if (row < 0 || CourseOnTrack() < 0 || courses[CourseOnTrack()].name != watchTrack) return;
    Leaderboard::WatchRowReplay(row, id, replayTexts[k]);
}

// The chosen ghost's replay handed to the game, for its row as the board shows it now.
void StartGhost()
{
    int k = replayKeys.find(ghostTrack + "|" + ghostId);
    if (ghostId == "" || k < 0) return;
    string replay = replayTexts[k];
    int row = shownIds.find(ghostId);
    if (row < 0 || CourseOnTrack() < 0 || courses[CourseOnTrack()].name != ghostTrack) return;
    if (!Leaderboard::SetRowGhost(row, ghostId, replay)) ghostId = "";
}

void ShowBoard(Board@ b)
{
    array<string> names = b.names;
    array<double> times = b.times;
    array<int> ranks = b.ranks;
    shownIds = b.ids;
    int highlight = -1;
    for (uint i = 0; i < ranks.length(); i++)
        if (ranks[i] == b.myRank && b.myRank > 0 && times[i] == b.myTime) highlight = int(i);
    if (highlight < 0 && b.myRank > 0) {             // your own place below the top
        names.insertLast(hsSteamId != "" && Steam::PersonaName(hsSteamId) != "" ? Steam::PersonaName(hsSteamId) : "you");
        times.insertLast(b.myTime);
        ranks.insertLast(b.myRank);
        shownIds.insertLast(hsSteamId);
        highlight = int(names.length()) - 1;
    }
    array<bool> ghosts;
    string lit = Leaderboard::RowGhost();
    for (uint i = 0; i < shownIds.length(); i++) ghosts.insertLast(lit != "" && shownIds[i] == lit);
    string title = b.loaded ? "online" + (b.total > 0 ? "  " + b.total + (b.total == 1 ? " player" : " players") : "  no times yet")
                            : (hsState != "" ? "online: offline" : "online: loading");
    hsShownKey = Race::TrackKey();
    Leaderboard::SetSource(hsShownKey, title, names, times, ranks, highlight, ghosts);
}

// The landing page: the courses' online boards fetched again when it opens.
void HiscoresPageOpened(const array<string> &in tracks)
{
    for (uint i = 0; i < tracks.length(); i++) Enqueue("top", tracks[i]);
}

// One line per course for the landing page: the record and your place.
string HiscoresLine(const string &in track)
{
    Board@ b = BoardOf(track);
    if (!b.loaded) return hsState != "" ? "online: offline" : "online: ...";
    if (b.times.length() == 0) return "online: no times yet";
    string line = "WR " + FormatTime(b.times[0]);
    if (b.myRank > 0) line += "  you #" + b.myRank + "/" + b.total;
    else line += "  " + b.total + (b.total == 1 ? " player" : " players");
    return line;
}

void HiscoresDisabled()
{
    Leaderboard::ClearRowGhost();
    Race::ClearSplitReference();
    splitsShown = "<none>";
    Leaderboard::ClearSource();
    hsShownKey = "";
}
