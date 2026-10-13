// The Mushroom Cup as a custom campaign in the game's own track selection (the host's Campaigns API): a card
// under the play page's "custom campaigns" tab, and its own screen there with the four courses (picture, best time,
// the online record under the title). Choosing a course races it (StartCourse in main.as); back from the race, the
// cup's screen opens again. The host draws the screens; this file keeps their text up to date.

int cupId = 0;
string cupStatus = "";              // why a course couldn't be opened, shown under the back bar
float cupRefresh = 0;

void CampaignStart()
{
    cupId = Campaigns::Register("Mushroom Cup", "images/mushroom_cup.png",
                                "Luigi Circuit, Moo Moo Meadows, Mushroom Gorge and Toad's Factory: race each course for your best time.");
    // Mario Kart's Mushroom Cup colours: mushroom red cards with cream lettering and a gold rim; gold with dark
    // lettering under the mouse.
    Campaigns::SetTheme(cupId, "card=#E60012 hover=#FFC20E pressed=#E0A400 text=#FFF3D6 body=#FFE2B8 "
                               "hovertext=#3A1600 accent=#FFC20E number=#FFC20E");
    for (uint i = 0; i < courses.length(); i++)
        Campaigns::AddCourse(cupId, courses[i].title, "images/" + courses[i].image);
    CampaignRefresh();
}

void CampaignStatus(const string &in s)
{
    cupStatus = s;
    CampaignRefresh();
}

// Best times on the cards, the online record under each title, the cup total (or a problem) as the note.
void CampaignRefresh()
{
    double total = 0;
    bool complete = true;
    for (uint i = 0; i < courses.length(); i++) {
        Course@ c = courses[i];
        Campaigns::SetCourseInfo(cupId, int(i), c.best < 0 ? "no time yet" : FormatTime(c.best));
        Campaigns::SetCourseDetail(cupId, int(i), HiscoresLine(c.name));
        if (c.best < 0)
            complete = false;
        else
            total += c.best;
    }
    string note = complete ? "cup total  " + FormatTime(total) : "set a time on every course for a cup total";
    Campaigns::SetNote(cupId, cupStatus != "" ? cupStatus : note);
}

void CampaignUpdate(float dt)
{
    if (cupId == 0)
        return;
    if (Campaigns::Opened(cupId)) {
        Load();
        cupStatus = "";
        array<string> tracks;
        for (uint i = 0; i < courses.length(); i++)
            tracks.insertLast(courses[i].name);
        HiscoresPageOpened(tracks);
        CampaignRefresh();
    }
    if (Campaigns::Shown(cupId)) {
        cupRefresh += dt;
        if (cupRefresh > 0.5f) {        // the online lines fill in as their requests come back
            cupRefresh = 0;
            CampaignRefresh();
        }
    }
    int picked = Campaigns::Picked(cupId);
    if (picked >= 0)
        StartCourse(picked);
    // Back from one of the cup's races (at the main menu): the cup's screen again.
    bool menu = UI::MainMenuShown() && !Race::OnTrack() && !Editor::IsOpen();
    if (menu && fromCampaign && sinceOpen > 3) {
        fromCampaign = false;
        raceCourse = -1;
        Campaigns::Show(cupId);
    }
}
