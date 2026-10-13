// The course models (part of MK Campaign; private, never publish): when a map whose name has a model in tracks/ is open, its original textured,
// smooth model (exported by ballest-map-builder/scripts/export_overlay.py into the map's own coordinates) is drawn
// over it; the map's pieces underneath stay for the collision. tracks/<map name>.txt is the model text
// ("mesh <file.glb> at=x,y,z": the bottom centre of the model at that point of the map).
//
// The pieces themselves (collision-only, in the invisible material M_Empty) are not drawn at all once the model is up
// (Editor::HideByMaterial, host 0.26.0): even invisible, 15k-38k of them cost a lot of frame time (measured overview:
// 38 fps drawn, 139-171 fps not drawn). Their collision stays. Hiding is repeated only after something that brings new
// pieces: the overlay drawn for a map, a test run starting or ending, or the level loaded again under the same name
// (the overlay's own actors are gone then: Draw::Show says so). Pieces come in over a few seconds when a map opens, so
// each time it is repeated every half second until two calls in a row find the same number of pieces.
//
// The model stays while a test run plays (the race reports no track name for an editor map) and goes when another
// map opens. The same map raced as a normal race (MK Campaign opens it with Tracks::OpenLocal, as a workshop map) is
// found by Race::TrackName, which is the map's display name there ("MK Luigi Circuit", measured); its pieces are
// actors of the race's own level, which Editor::HideByMaterial also covers.

const string kCollisionMaterial = "/Game/Art/Materials/Masters/M_Empty";

// Mushroom bounce: tracks/<map name>.bounce lists the course's trampolines (written by ballest-map-builder's
// mechanics.py): per cap its centre, radius and the height of its top surface in 8 rings out from the centre (map cm).
// Each frame, a ball on a cap's top surface, or touching its side, is sent straight up (Race::AddBallVelocity: only the player's own
// unpublished map), keeping its speed along the ground: about 10 m up, or as high as it came down from (to a cap).
// The cap itself is solid (the overlay's collision); nothing bouncy is in the map.
const double kBallRadius = 47.5;      // BP_RollingBall: 50 cm x scale 0.95
const double kBounceUp = 1400;        // cm/s up: 10 m with the game's 980 cm/s^2
const double kBounceMax = 2500;
const string kBounceSound = "/Game/Sound/Gameplay/Rubber_Ball_Bounce_01.Rubber_Ball_Bounce_01";   // the rubber pieces' bounce

class Cap
{
    double x, y, r, bottom;
    array<double> top;
}
array<Cap@> caps;
float bounceWait = 0;

string shown = "";
int shape = 0;
int decals = 0;         // tracks/<map name>.decals.txt: dash panels' arrows, road marks, drawn over the road, not solid
bool collides = false;
float since = 0;
bool testing = false;
int settling = 0;       // hiding passes still to make: > 0 after the pieces may have changed
int lastHidden = -1;

void Show(const string &in name)
{
    if (shape != 0) Draw::Remove(shape);
    if (decals != 0) Draw::Remove(decals);
    shape = 0;
    decals = 0;
    shown = name;
    LoadCaps(name);
    if (name == "") return;
    shape = Draw::Model(Plugins::Folder() + "tracks/" + name + ".txt");
    if (shape == 0) return;
    // the model itself is the driving surface (host 0.26.0 Draw::Collide): the ball rolls on exactly what is drawn,
    // one continuous surface. Only allowed on the player's own unpublished map; the maps carry no collision pieces.
    collides = Draw::Collide(shape);
    if (Plugins::ReadFile("tracks/" + name + ".decals.txt") != "")
        decals = Draw::Model(Plugins::Folder() + "tracks/" + name + ".decals.txt");
    Log::Info("overlay for '" + name + "' drawn" + (collides ? ", solid" : ", NOT solid"));
}

void LoadCaps(const string &in name)
{
    caps.resize(0);
    if (name == "") return;
    array<string>@ lines = Plugins::ReadFile("tracks/" + name + ".bounce").split("\n");
    for (uint i = 0; i < lines.length(); i++) {
        array<string>@ w = lines[i].split(" ");
        if (w.length() != 13 || w[0] != "cap") continue;
        Cap c;
        c.x = parseFloat(w[1]);
        c.y = parseFloat(w[2]);
        c.r = parseFloat(w[3]);
        c.bottom = parseFloat(w[4]);
        for (uint k = 5; k < 13; k++) c.top.insertLast(parseFloat(w[k]));
        caps.insertLast(c);
    }
    if (caps.length() > 0) Log::Info(caps.length() + " bouncy mushroom caps on '" + name + "'");
}

void Bounce(float dt)
{
    if (caps.length() == 0) return;
    bounceWait -= dt;
    if (bounceWait > 0 || !(Editor::IsTesting() || Race::OnTrack())) return;
    double x, y, z, vx, vy, vz;
    if (!Race::BallPosition(x, y, z) || !Race::BallVelocity(vx, vy, vz)) return;
    for (uint i = 0; i < caps.length(); i++) {
        Cap@ c = caps[i];
        double r = Math::sqrt((x - c.x) * (x - c.x) + (y - c.y) * (y - c.y));
        if (r > c.r + kBallRadius + 10) continue;
        int ring = int(r / c.r * 8);
        if (ring > 7) ring = 7;
        double gap = z - kBallRadius - c.top[ring];
        bool onTop = r <= c.r && gap >= -60 && gap <= 25;
        // touching its side (the rim, below the top): sent up high enough to land on it, as the karts are
        bool onSide = r > c.r - 30 && z > c.bottom - kBallRadius && z < c.top[7] + kBallRadius;
        if (!onTop && !onSide) continue;
        double up = -vz;                                // as high as it came down from...
        if (up < kBounceUp) up = kBounceUp;            // ...but at least 10 m (a cap is at most ~4 m tall)
        if (up > kBounceMax) up = kBounceMax;
        if (vz >= up * 0.5) return;                    // already on its way up
        Race::AddBallVelocity(0, 0, up - vz);
        Draw::Sound(kBounceSound, 1, 1);
        bounceWait = 0.25;
        return;
    }
}

void Resettle()
{
    settling = 60;          // up to 30 s of pieces still coming in
    lastHidden = -1;
}

// F8 in a race or test run: remember where the ball is (Storage "mark:<map>:<n>" = x y z heading, map cm and degrees),
// so a spot on the course can be pointed at ("mark 2 needs fixing") and found in the model.
void Mark()
{
    if (!Input::Pressed(Input::F8) || shown == "" || !(Editor::IsTesting() || Race::OnTrack())) return;
    double x, y, z, vx, vy, vz;
    if (!Race::BallPosition(x, y, z)) return;
    Race::BallVelocity(vx, vy, vz);
    int n = parseInt(Storage::Get("marks:" + shown, "0")) + 1;
    Storage::Set("marks:" + shown, "" + n);
    string at = int(x) + " " + int(y) + " " + int(z) + " " + int(Math::atan2(vy, vx) * 180 / 3.14159265);
    Storage::Set("mark:" + shown + ":" + n, at);
    Log::Info("mark " + n + " on '" + shown + "': " + at);
}

void OverlayUpdate(float dt)
{
    Mark();
    Bounce(dt);
    since += dt;
    if (since < 0.5) return;
    since = 0;
    string name = Editor::MapName();
    if (name == "") name = Race::TrackName();
    if (name != "" && name != shown) {
        Resettle();
        Show(name);
    } else if (shape != 0 && !Draw::Show(shape, true) && (Editor::IsOpen() || Editor::IsTesting() || Race::OnTrack())) {
        Log::Info("the level was loaded again: drawing the overlay again");
        Resettle();
        Show(shown);
    }
    if (shape != 0 && !collides) collides = Draw::Collide(shape);     // e.g. refused while a level was still loading
    bool nowTesting = Editor::IsTesting();
    if (nowTesting != testing) {
        testing = nowTesting;
        Resettle();
    }
    if (shape == 0 || settling <= 0) return;
    settling--;
    int hidden = Editor::HideByMaterial(kCollisionMaterial);
    if (hidden > 0 && hidden == lastHidden) {
        settling = 0;
        Log::Info(hidden + " collision pieces not drawn");
    }
    lastHidden = hidden;
}

void OverlayDisabled()
{
    if (shape != 0) Draw::Remove(shape);
    if (decals != 0) Draw::Remove(decals);
    shape = 0;
    decals = 0;
    shown = "";
    caps.resize(0);
    Editor::ShowAll();
}
