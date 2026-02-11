#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_functions>

// ================================================================
// Info
// ================================================================

public Plugin myinfo = {
    name        = "[L4D2] Infected Sound Throttle",
    author      = "Ren",
    description = "Throttles infected audio spam so it doesn't drown out the game.",
    version     = "1.0.0",
    url         = "N/A"
};

// ================================================================
// Constants
// ================================================================

#define CHAT_PREFIX "[InfSndThrottle]"

#define ENTITY_TRACK_MAX 2048
#define GLOBAL_RING_SIZE 2048

// ================================================================
// ConVars
// ================================================================

ConVar g_cvEnable;
ConVar g_cvMode;

ConVar g_cvGlobalLimit;
ConVar g_cvWindow;

ConVar g_cvEntityInterval;

ConVar g_cvSampleInterval;
ConVar g_cvSampleMatch;

ConVar g_cvScale;
ConVar g_cvScaleFloor;

ConVar g_cvDebug;

// ================================================================
// Cached settings
// ================================================================

bool  g_bEnable = true;
int   g_nMode = 0;

int   g_nGlobalLimit = 0;
float g_flWindow = 0.0;

float g_flEntityInterval = 0.0;

float g_flSampleInterval = 0.0;
bool  g_bSampleMatch = true;

float g_flScale = 0.25;
float g_flScaleFloor = 0.05;

bool  g_bDebug = false;

// ================================================================
// State
// ================================================================

float g_flLastEntitySoundTime[ENTITY_TRACK_MAX + 1];

float g_flGlobalSoundTimes[GLOBAL_RING_SIZE];
int   g_nGlobalRingHead = 0;
int   g_nGlobalRingCount = 0;

StringMap g_smSampleLastTime = null;

// ================================================================
// Leaf-level helpers
// ================================================================

static bool IsClientIndex(int nEntityIndex) {
    return ((nEntityIndex > 0) && (nEntityIndex <= MaxClients));
}

static bool IsValidEntityIndex(int nEntityIndex) {
    if (nEntityIndex <= 0) {
        return false;
    }

    if (!IsValidEdict(nEntityIndex)) {
        return false;
    }

    return IsValidEntity(nEntityIndex);
}

static bool IsInfectedClient(int nClient) {
    if (!IsClientIndex(nClient)) {
        return false;
    }

    if (!IsClientInGame(nClient)) {
        return false;
    }

    return (GetClientTeam(nClient) == 3);
}

static bool IsInfectedEntityByTeamProp(int nEntityIndex) {
    if (!IsValidEntityIndex(nEntityIndex)) {
        return false;
    }

    if (!HasEntProp(nEntityIndex, Prop_Send, "m_iTeamNum")) {
        return false;
    }

    int nTeam = GetEntProp(nEntityIndex, Prop_Send, "m_iTeamNum");

    return nTeam == 3;
}

static bool IsInfectedEntityByClassname(int nEntityIndex) {
    if (!IsValidEntityIndex(nEntityIndex)) {
        return false;
    }

    char szClassName[64];
    GetEntityClassname(nEntityIndex, szClassName, sizeof(szClassName));

    if (StrEqual(szClassName, "infected", false)) {
        return true;
    }

    if (StrEqual(szClassName, "witch", false)) {
        return true;
    }

    if (StrEqual(szClassName, "witch_bride", false)) {
        return true;
    }

    return false;
}

static bool IsEntityInfected(int nEntityIndex) {
    if (nEntityIndex <= 0) {
        return false;
    }

    if (IsClientIndex(nEntityIndex)) {
        return IsInfectedClient(nEntityIndex);
    }

    if (!IsValidEdict(nEntityIndex)) {
        return false;
    }

    if (IsInfectedEntityByTeamProp(nEntityIndex)) {
        return true;
    }

    return IsInfectedEntityByClassname(nEntityIndex);
}

static bool IsSampleLikelyInfected(const char[] szSample) {
    if (szSample[0] == '\0') {
        return false;
    }

    if (StrContains(szSample, "npc/infected", false) != -1) { return true; }
    if (StrContains(szSample, "npc/witch", false) != -1)    { return true; }

    if (StrContains(szSample, "player/boomer", false)  != -1) { return true; }
    if (StrContains(szSample, "player/hunter", false)  != -1) { return true; }
    if (StrContains(szSample, "player/smoker", false)  != -1) { return true; }
    if (StrContains(szSample, "player/spitter", false) != -1) { return true; }
    if (StrContains(szSample, "player/charger", false) != -1) { return true; }
    if (StrContains(szSample, "player/jockey", false)  != -1) { return true; }
    if (StrContains(szSample, "player/tank", false)    != -1) { return true; }
    if (StrContains(szSample, "player/witch", false)   != -1) { return true; }

    return false;
}

static float ClampFloat(float flValue, float flMinimum, float flMaximum) {
    if (flValue < flMinimum) {
        return flMinimum;
    }

    if (flValue > flMaximum) {
        return flMaximum;
    }

    return flValue;
}

static void ResetGlobalRing() {
    g_nGlobalRingHead = 0;
    g_nGlobalRingCount = 0;
}

static void PruneGlobalRing(float flNow) {
    if (g_flWindow <= 0.0) {
        ResetGlobalRing();
        return;
    }

    float flCutTime = flNow - g_flWindow;

    while (g_nGlobalRingCount > 0) {
        float flOldestTime = g_flGlobalSoundTimes[g_nGlobalRingHead];
        if (flOldestTime >= flCutTime) {
            break;
        }

        g_nGlobalRingHead = (g_nGlobalRingHead + 1) % GLOBAL_RING_SIZE;
        g_nGlobalRingCount--;
    }
}

static void PushGlobalRing(float flNow) {
    if (g_nGlobalRingCount >= GLOBAL_RING_SIZE) {
        return;
    }

    int nWriteIndex = (g_nGlobalRingHead + g_nGlobalRingCount) % GLOBAL_RING_SIZE;
    g_flGlobalSoundTimes[nWriteIndex] = flNow;
    g_nGlobalRingCount++;
}

// ================================================================
// Mid-level helpers
// ================================================================

static void ResetPluginState() {
    for (int nEntityIndex = 0; nEntityIndex <= ENTITY_TRACK_MAX; nEntityIndex++) {
        g_flLastEntitySoundTime[nEntityIndex] = 0.0;
    }

    ResetGlobalRing();

    if (g_smSampleLastTime != null) {
        g_smSampleLastTime.Clear();
    }
}

static void RefreshCvars() {
    g_bEnable          = g_cvEnable.BoolValue;
    g_nMode            = g_cvMode.IntValue;

    g_nGlobalLimit     = g_cvGlobalLimit.IntValue;
    g_flWindow         = g_cvWindow.FloatValue;

    g_flEntityInterval = g_cvEntityInterval.FloatValue;

    g_flSampleInterval = g_cvSampleInterval.FloatValue;
    g_bSampleMatch     = g_cvSampleMatch.BoolValue;

    g_flScale          = g_cvScale.FloatValue;
    g_flScaleFloor     = g_cvScaleFloor.FloatValue;

    g_bDebug           = g_cvDebug.BoolValue;

    if (g_nMode < 0) { g_nMode = 0; }
    if (g_nMode > 1) { g_nMode = 1; }

    if (g_nGlobalLimit < 0) { g_nGlobalLimit = 0; }

    if (g_flWindow < 0.0) { g_flWindow = 0.0; }
    if (g_flEntityInterval < 0.0) { g_flEntityInterval = 0.0; }
    if (g_flSampleInterval < 0.0) { g_flSampleInterval = 0.0; }

    g_flScale = ClampFloat(g_flScale, 0.0, 1.0);
    g_flScaleFloor = ClampFloat(g_flScaleFloor, 0.0, 1.0);
}

public void OnConVarChanged(ConVar cv, const char[] szOldValue, const char[] szNewValue) {
    RefreshCvars();
}

static bool ShouldTreatAsInfectedSource(int nEntityIndex, const char[] szSample) {
    if (IsEntityInfected(nEntityIndex)) {
        return true;
    }

    if (g_bSampleMatch && IsSampleLikelyInfected(szSample)) {
        return true;
    }

    return false;
}

static bool IsThrottledBySample(float flNow, const char[] szSample) {
    if (g_flSampleInterval <= 0.0) {
        return false;
    }

    if (g_smSampleLastTime == null) {
        return false;
    }

    int nBits;
    if (!g_smSampleLastTime.GetValue(szSample, nBits)) {
        return false;
    }

    float flLastTime = view_as<float>(nBits);
    return ((flNow - flLastTime) < g_flSampleInterval);
}

static void RememberSampleTime(const char[] szSample, float flNow) {
    if (g_smSampleLastTime == null) {
        return;
    }

    g_smSampleLastTime.SetValue(szSample, view_as<int>(flNow), true);
}

static void DebugPrintBlock(int nEntityIndex, int nChannel, float flVolume, const char[] szSample) {
    if (!g_bDebug) {
        return;
    }

    PrintToServer("%s BLOCK ent=%d ch=%d vol=%.2f sample=%s", CHAT_PREFIX, nEntityIndex, nChannel, flVolume, szSample);
}

static void DebugPrintScale(int nEntityIndex, int nChannel, float flOldVolume, float flNewVolume, const char[] szSample) {
    if (!g_bDebug) {
        return;
    }

    PrintToServer("%s SCALE ent=%d ch=%d %.2f->%.2f sample=%s", CHAT_PREFIX, nEntityIndex, nChannel, flOldVolume, flNewVolume, szSample);
}

// ================================================================
// Entry points (last)
// ================================================================

public void OnPluginStart() {
    g_cvEnable          = CreateConVar("l4d2_infected_snd_throttle_enable", "1", "Enable infected sound throttling", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvMode            = CreateConVar("l4d2_infected_snd_throttle_mode", "0", "0=block throttled sounds, 1=scale volume", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvGlobalLimit     = CreateConVar("l4d2_infected_snd_throttle_global_limit", "20", "Max infected sounds per window (0=off)", FCVAR_NOTIFY, true, 0.0);
    g_cvWindow          = CreateConVar("l4d2_infected_snd_throttle_window", "1.0", "Window size in seconds for global_limit", FCVAR_NOTIFY, true, 0.0);

    g_cvEntityInterval  = CreateConVar("l4d2_infected_snd_throttle_entity_interval", "0.06", "Min interval per infected entity (0=off)", FCVAR_NOTIFY, true, 0.0);

    g_cvSampleInterval  = CreateConVar("l4d2_infected_snd_throttle_sample_interval", "0.02", "Min interval per sample path (0=off)", FCVAR_NOTIFY, true, 0.0);
    g_cvSampleMatch     = CreateConVar("l4d2_infected_snd_throttle_sample_match", "1", "Also throttle when sample path looks infected even if entity isn't (useful for entity=0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvScale           = CreateConVar("l4d2_infected_snd_throttle_scale", "0.25", "Volume multiplier in mode=1 when throttled", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvScaleFloor      = CreateConVar("l4d2_infected_snd_throttle_scale_floor", "0.05", "Minimum volume in mode=1 when throttled", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvDebug           = CreateConVar("l4d2_infected_snd_throttle_debug", "0", "Debug logging", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarChange(g_cvEnable, OnConVarChanged);
    HookConVarChange(g_cvMode, OnConVarChanged);

    HookConVarChange(g_cvGlobalLimit, OnConVarChanged);
    HookConVarChange(g_cvWindow, OnConVarChanged);

    HookConVarChange(g_cvEntityInterval, OnConVarChanged);

    HookConVarChange(g_cvSampleInterval, OnConVarChanged);
    HookConVarChange(g_cvSampleMatch, OnConVarChanged);

    HookConVarChange(g_cvScale, OnConVarChanged);
    HookConVarChange(g_cvScaleFloor, OnConVarChanged);

    HookConVarChange(g_cvDebug, OnConVarChanged);

    AutoExecConfig(true, "l4d2_infected_sound_throttle");

    if (g_smSampleLastTime == null) {
        g_smSampleLastTime = new StringMap();
    }

    RefreshCvars();
    ResetPluginState();

    AddNormalSoundHook(NormalSoundHook);
}

public void OnMapStart() {
    ResetPluginState();
}

public Action NormalSoundHook(int clients[64], int &numClients, char szSample[PLATFORM_MAX_PATH], int &nEntityIndex, int &nChannel, float &flVolume, int &nLevel, int &nPitch, int &nFlags) {
    if (!g_bEnable) {
        return Plugin_Continue;
    }

    if (!ShouldTreatAsInfectedSource(nEntityIndex, szSample)) {
        return Plugin_Continue;
    }

    float flNow = GetGameTime();
    bool bThrottle = false;

    if (g_nGlobalLimit > 0) {
        PruneGlobalRing(flNow);

        if (g_nGlobalRingCount >= g_nGlobalLimit) {
            bThrottle = true;
        }
    }

    if (!bThrottle && (g_flEntityInterval > 0.0) && (nEntityIndex > 0) && (nEntityIndex <= ENTITY_TRACK_MAX)) {
        float flLastTime = g_flLastEntitySoundTime[nEntityIndex];
        if ((flNow - flLastTime) < g_flEntityInterval) {
            bThrottle = true;
        }
    }

    if (!bThrottle && IsThrottledBySample(flNow, szSample)) {
        bThrottle = true;
    }

    if (bThrottle) {
        if (g_nMode == 0) {
            DebugPrintBlock(nEntityIndex, nChannel, flVolume, szSample);
            return Plugin_Handled;
        }

        float flNewVolume = flVolume * g_flScale;
        if (flNewVolume < g_flScaleFloor) {
            flNewVolume = g_flScaleFloor;
        }

        flNewVolume = ClampFloat(flNewVolume, 0.0, 1.0);

        DebugPrintScale(nEntityIndex, nChannel, flVolume, flNewVolume, szSample);

        flVolume = flNewVolume;
        return Plugin_Changed;
    }

    if (g_nGlobalLimit > 0) {
        PushGlobalRing(flNow);
    }

    if ((g_flEntityInterval > 0.0) && (nEntityIndex > 0) && (nEntityIndex <= ENTITY_TRACK_MAX)) {
        g_flLastEntitySoundTime[nEntityIndex] = flNow;
    }

    if (g_flSampleInterval > 0.0) {
        RememberSampleTime(szSample, flNow);
    }

    return Plugin_Continue;
}
