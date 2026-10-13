// MK Campaign (PRIVATE: never publish, never add to the registry). A "mushroom cup" entry in the main menu's own list
// opens a Mushroom Cup landing page: the cup's four courses in order, each with a picture and the player's best time. Picking one races its map as a normal race, the way the game races a workshop map
// (Tracks::OpenLocal: countdown, timer, checkpoints, finish screen, improve), not the editor's test run. Leaving the
// race (exit) comes back to the landing page.
//
// The maps are the player's own saved maps ("Map_LevelEditorMain&MK <Course>_AnythingGoes.balledit" in the game's
// UserSavedMaps folder), never published. Their runs never reach a leaderboard: the game makes no leaderboard upload
// for a map that was never published (measured: no Steam leaderboard call at a finish), and the host refuses one for
// any local map anyway (the upload guard, track key "custom:local:...").
//
// Records are this plugin's own (Storage): the best time per course and that run's checkpoint splits (the game's own
// timer shows the split deltas during a race). The game also keeps its own best for the map in the player's profile.

class Course
{
    string name;        // as the map calls itself ("MK Luigi Circuit": Race::TrackName in its race)
    string title;       // as the page shows it
    string image;       // picture file in images/
    double best = -1;
    array<double> splits;
}

array<Course@> courses;
UI::FooterButton@ menuButton;
UI::Window@ page;
array<UI::Text@> bestTexts;
array<UI::Text@> onlineTexts;       // hiscores.as: the course's online record and your place
array<UI::Button@> raceButtons;
array<int> raceLooks;                // what each race button shows now: 0 normal, 1 hovered, 2 pressed
UI::Button@ backButton;
UI::Text@ statusText, totalText;

UI::Window@ hud;
UI::Text@ hudBest;

bool pageOpen = false;
bool fromCampaign = false;          // the race now (or the last one) was opened from the landing page
int raceCourse = -1;                // the course being raced
float sinceOpen = 0;
string openingFile = "";

// The run going on now
int runId = -2;
array<double> runSplits;
array<int> reached;                 // checkpoint indices reached this run, in order
int lastCheckpoint = -1;
string handledRun = "";             // Runs::Id of the last finish handled

const string kFont = "/Game/UI/Fonts/CocogoosePro.CocogoosePro";

void AddCourse(const string &in name, const string &in title, const string &in image)
{
    Course c;
    c.name = name;
    c.title = title;
    c.image = image;
    courses.insertLast(c);
}

string FileOf(Course@ c) { return "Map_LevelEditorMain&" + c.name + "_AnythingGoes.balledit"; }

string FormatTime(double t)
{
    if (t < 0)
        return "--:--.---";
    int ms = int(t * 1000 + 0.5);
    int m = ms / 60000;
    int s = (ms / 1000) % 60;
    int r = ms % 1000;
    return m + ":" + (s < 10 ? "0" : "") + s + "." + (r < 100 ? "0" : "") + (r < 10 ? "0" : "") + r;
}

// Best times are the player's ONLINE bests (hiscores.as caches them as "hiscores:best:<course>" = "<total>|<splits>"):
// the cup page, the cup total and the in-race BEST box all show what the online board holds. Older versions kept a
// local record of their own ("best:<course>", "splits:<course>"); it's cleared once (data version 2).
double OnlineBest(const string &in name)
{
    string s = Storage::Get("hiscores:best:" + name, "");
    int bar = s.findFirst("|");
    if (s == "" || bar <= 0)
        return -1;
    double t = parseFloat(s.substr(0, bar));
    return t > 0 ? t : -1;
}

void RefreshBests()
{
    for (uint i = 0; i < courses.length(); i++)
        courses[i].best = OnlineBest(courses[i].name);
}

void Load()
{
    if (Storage::Get("data:version", "1") != "2") {
        for (uint i = 0; i < courses.length(); i++) {
            Storage::Set("best:" + courses[i].name, "");
            Storage::Set("splits:" + courses[i].name, "");
        }
        Storage::Set("data:version", "2");
        Log::Info("the old local best times are cleared: the cup shows the online bests");
    }
    RefreshBests();
}


// --- the landing page ---------------------------------------------------------------------------------------------
// Mario Kart Wii's cup screens: a deep blue backdrop, the cup's red-and-white mushroom badge, the four courses in
// order as red cards with white lettering. Colours are linear (sRGB red 0.89,0.0,0.06 -> 0.77,0,0.005).

void BuildPage()
{
    @page = UI::CreateWindow();
    page.SetFont(kFont, "Regular");
    page.SetBackground(0.006f, 0.02f, 0.13f, 1);
    page.SetCardBackground(0.62f, 0.004f, 0.006f, 1);
    page.SetCornerRadius(18);
    page.SetPadding(36, 20);
    page.SetRowGap(8);
    page.SetBlocksClicks(true);
    page.zOrder = 400;

    page.AddImage(Plugins::Folder() + "images/mushroom_cup.png", 104, 104);
    UI::Text@ title = page.AddText("MUSHROOM CUP", 58);
    title.SetGapBefore(22);
    title.SetColor(1, 1, 1, 1);
    page.AddSpace(0);
    @backButton = page.AddButton("back");
    backButton.SetBackground(1, 1, 1, 1);
    backButton.SetTextColor(0.62f, 0.004f, 0.006f, 1);
    backButton.SetCornerRadius(22);
    page.NewRow();
    @totalText = page.AddText("", 22);
    totalText.SetColor(1, 0.6f, 0.01f, 1);
    page.AddSpace(0);
    @statusText = page.AddText("", 18);
    statusText.SetColor(1, 0.35f, 0.3f, 1);

    for (uint i = 0; i < courses.length(); i++) {
        Course@ c = courses[i];
        page.NewRow();
        page.StartCard();
        UI::Text@ number = page.AddText("" + (i + 1), 40);
        number.SetWidth(46);
        number.SetAlign(1);
        number.SetColor(1, 0.6f, 0.01f, 1);
        UI::Image@ picture = page.AddImage(Plugins::Folder() + "images/" + c.image, 192, 108);
        picture.SetGapBefore(14);
        UI::Text@ name = page.AddText(c.title, 38);
        name.SetGapBefore(24);
        name.SetWidth(560);
        name.SetColor(1, 1, 1, 1);
        UI::Text@ best = page.AddText("", 34);
        best.SetWidth(240);
        best.SetAlign(2);
        best.SetColor(1, 1, 1, 1);
        bestTexts.insertLast(best);
        UI::Text@ online = page.AddText("", 18);
        online.SetGapBefore(16);
        online.SetWidth(320);
        online.SetColor(1, 0.6f, 0.01f, 1);
        onlineTexts.insertLast(online);
        UI::Button@ race = page.AddButton("race");
        race.SetGapBefore(30);
        race.SetBackground(1, 1, 1, 1);
        race.SetTextColor(0.62f, 0.004f, 0.006f, 1);
        race.SetCornerRadius(24);
        raceButtons.insertLast(race);
        raceLooks.insertLast(-1);
        page.EndCard();
    }
    page.visible = false;
    RefreshPage();
}

void PlacePage()
{
    float w, h;
    if (!UI::ScreenSize(w, h))
        return;
    float footer = UI::FooterHeight();
    page.SetRect(w * 0.04f, h * 0.045f, w * 0.92f, h - footer - h * 0.07f);
}

void RefreshPage()
{
    double total = 0;
    bool complete = true;
    for (uint i = 0; i < courses.length(); i++) {
        Course@ c = courses[i];
        bestTexts[i].text = c.best < 0 ? "no time yet" : FormatTime(c.best);
        onlineTexts[i].text = HiscoresLine(c.name);
        if (c.best < 0)
            complete = false;
        else
            total += c.best;
    }
    totalText.text = complete ? "cup total  " + FormatTime(total) : "set a time on every course for a cup total";
}

// The race buttons' hover and press looks. A rounded button's own state brushes tint its background (hovered x1.45,
// pressed x0.75: host widgets.cpp RoundButton), which does nothing visible on white, so the button's colour follows
// its state: white, gold when hovered, orange with white lettering while held down. The colours below are
// set before that tint (gold 1,0.6,0.01 shown = 0.69,0.414,0.007 set), and a press also gets the native x0.75
// darkening, so it reads as pressed even where the mouse button state isn't seen (Input::Down needs window focus).
void StyleRaceButton(uint i, int look)
{
    if (raceLooks[i] == look)
        return;
    raceLooks[i] = look;
    UI::Button@ b = raceButtons[i];
    if (look == 2) {
        b.SetBackground(1.0f, 0.27f, 0.0f, 1);
        b.SetTextColor(1, 1, 1, 1);
    } else if (look == 1) {
        b.SetBackground(0.69f, 0.414f, 0.007f, 1);
        b.SetTextColor(0.62f, 0.004f, 0.006f, 1);
    } else {
        b.SetBackground(1, 1, 1, 1);
        b.SetTextColor(0.62f, 0.004f, 0.006f, 1);
    }
}

void UpdateRaceButtons()
{
    bool down = Input::Down(Input::Key::MouseLeft);
    for (uint i = 0; i < raceButtons.length(); i++) {
        bool over = raceButtons[i].hovered;
        StyleRaceButton(i, over ? (down ? 2 : 1) : 0);
    }
}

void OpenPage()
{
    Load();
    RefreshPage();
    PlacePage();
    statusText.text = "";
    array<string> tracks;
    for (uint i = 0; i < courses.length(); i++) tracks.insertLast(courses[i].name);
    HiscoresPageOpened(tracks);
    page.visible = true;
    pageOpen = true;
}

void ClosePage()
{
    page.visible = false;
    pageOpen = false;
}

void StartCourse(int i)
{
    Course@ c = courses[i];
    openingFile = FileOf(c);
    // The cup's four maps become the game's active playlist while they're raced, so the game's own "next track"
    // goes on to the next course.
    array<string> files;
    for (uint j = 0; j < courses.length(); j++)
        files.insertLast(FileOf(courses[j]));
    if (!Tracks::OpenLocalList(files, i)) {
        CampaignStatus(Tracks::OpenState());
        Log::Warn("couldn't open " + openingFile + ": " + Tracks::OpenState());
        return;
    }
    Log::Info("racing " + c.title);
    fromCampaign = true;
    raceCourse = i;
    sinceOpen = 0;
}

// --- during a race: best time (the game shows splits) ------------------------------------------------------------------

void BuildHud()
{
    @hud = UI::CreateWindow();
    hud.SetFont(kFont, "Regular");
    hud.SetBackground(0.62f, 0.004f, 0.006f, 0.88f);
    hud.SetCornerRadius(12);
    hud.SetPadding(16, 8);
    hud.SetAnchor(0, 0);
    hud.SetPivot(0, 0);
    hud.SetOffset(24, 96);
    hud.zOrder = 600;
    UI::Text@ label = hud.AddText("BEST", 16);
    label.SetColor(1, 0.6f, 0.01f, 1);
    label.SetWidth(70);
    @hudBest = hud.AddText("", 24);
    hudBest.SetColor(1, 1, 1, 1);
    hud.visible = false;
}

int CourseOnTrack()
{
    if (!Race::OnTrack() || Race::TrackKey().findFirst("custom:local:") != 0)
        return -1;
    string name = Race::TrackName();
    for (uint i = 0; i < courses.length(); i++)
        if (courses[i].name == name)
            return int(i);
    return -1;
}

void TrackRace(float dt, int ci)
{
    Course@ c = courses[ci];
    c.best = OnlineBest(c.name);                     // the server is the only record
    hudBest.text = c.best < 0 ? "--:--.---" : FormatTime(c.best);
    int id = Race::RunId();
    if (id >= 0 && id != runId) {            // a new run (the start, or a restart)
        runId = id;
        runSplits.resize(0);
        reached.resize(0);
        lastCheckpoint = Race::CurrentCheckpoint();
    }
    if (Race::IsActive()) {
        int cp = Race::CurrentCheckpoint();
        if (cp >= 0 && cp != lastCheckpoint && reached.find(cp) < 0) {
            double t = Runs::Elapsed();
            reached.insertLast(cp);
            runSplits.insertLast(t);
        }
        lastCheckpoint = cp;
    }
    // A finish: the host's newest run, finished, on this track, not handled yet.
    if (Runs::Count() > 0 && Runs::IsFinished(0) && Runs::Id(0) != handledRun && Runs::Age(0) < 10 &&
        Runs::TrackKey(0) == Race::TrackKey()) {
        handledRun = Runs::Id(0);
        double t = Runs::Time(0);
        Log::Info(c.title + ": finished in " + FormatTime(t) + " (sent to the online board)");
        HiscoresFinished(c.name, t, runSplits);
    }
}

// ------------------------------------------------------------------------------------------------------------------

void Main()
{
    AddCourse("MK Luigi Circuit", "Luigi Circuit", "luigi_circuit.png");
    AddCourse("MK Moo Moo Meadows", "Moo Moo Meadows", "moo_moo_meadows.png");
    AddCourse("MK Mushroom Gorge", "Mushroom Gorge", "mushroom_gorge.png");
    AddCourse("MK Toads Factory", "Toad's Factory", "toads_factory.png");
    Load();
    CampaignStart();                // campaigns.as: the cup in the game's track selection (no menu button)
    BuildHud();
    HiscoresStart();
}

void Update(float dt)
{
    OverlayUpdate(dt);
    sinceOpen += dt;
    CampaignUpdate(dt);             // campaigns.as: the cup's screen, a chosen course, back from a race
    int ci = CourseOnTrack();
    hud.visible = ci >= 0;
    if (ci >= 0) {
        if (ci != raceCourse)
            raceCourse = ci;
        fromCampaign = fromCampaign || ci >= 0;
        TrackRace(dt, ci);
    } else {
        runId = -2;
    }
    HiscoresUpdate(ci, ci >= 0 ? courses[ci].name : "");
}

void OnDisabled()
{
    OverlayDisabled();
    HiscoresDisabled();
    if (page !is null)
        page.visible = false;
    if (hud !is null)
        hud.visible = false;
}
