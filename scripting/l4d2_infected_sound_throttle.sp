#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// ================================================================
// Info
// ================================================================

#define PLUGIN_VERSION "1.0.0"

// ================================================================
// Constants
// ================================================================

#define ENTITY_TRACK_MAX 2048
#define GLOBAL_RING_SIZE 2048

// ================================================================
// ConVars (decl order == create order)
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

bool  g_bEnable;
int   g_nMode;
int   g_nGlobalLimit;
float g_flWindow;
float g_flEntityInterval;
float g_flSampleInterval;
bool  g_bSampleMatch;
float g_flScale;
float g_flScaleFloor;
bool  g_bDebug;

// ================================================================
// State
// ================================================================

float g_flLastEntityTime[ENTITY_TRACK_MAX + 1];

float g_flGlobalTimes[GLOBAL_RING_SIZE];
int   g_nGlobalHead;
int   g_nGlobalCount;

StringMap g_smSampleLast;

// ================================================================
// Leaf-level
// ================================================================

static bool IsEntityInfected(int nEntity)
{
    if (nEntity <= 0)
    {
        return false;
    }

    if (nEntity <= MaxClients)
    {
        if (!IsClientInGame(nEntity))
        {
            return false;
        }

        return (GetClientTeam(nEntity) == 3);
    }

    if (!IsValidEdict(nEntity))
    {
        return false;
    }

    if (HasEntProp(nEntity, Prop_Send, "m_iTeamNum"))
    {
        int nTeam = GetEntProp(nEntity, Prop_Send, "m_iTeamNum");
        if (nTeam == 3)
        {
            return true;
        }
    }

    char sClass[64];
    GetEntityClassname(nEntity, sClass, sizeof(sClass));

    if (StrEqual(sClass, "infected", false))
    {
        return true;
    }

    if (StrEqual(sClass, "witch", false))
    {
        return true;
    }

    if (StrEqual(sClass, "witch_bride", false))
    {
        return true;
    }

    return false;
}

static bool IsSampleLikelyInfected(const char[] sSample)
{
    if (sSample[0] == '\0')
    {
        return false;
    }

    if (StrContains(sSample, "npc/infected", false) != -1) { return true; }
    if (StrContains(sSample, "npc/witch", false) != -1)    { return true; }

    if (StrContains(sSample, "player/boomer", false)  != -1) { return true; }
    if (StrContains(sSample, "player/hunter", false)  != -1) { return true; }
    if (StrContains(sSample, "player/smoker", false)  != -1) { return true; }
    if (StrContains(sSample, "player/spitter", false) != -1) { return true; }
    if (StrContains(sSample, "player/charger", false) != -1) { return true; }
    if (StrContains(sSample, "player/jockey", false)  != -1) { return true; }
    if (StrContains(sSample, "player/tank", false)    != -1) { return true; }
    if (StrContains(sSample, "player/witch", false)   != -1) { return true; }

    return false;
}

static void PruneGlobal(float flNow)
{
    if (g_flWindow <= 0.0)
    {
        g_nGlobalHead = 0;
        g_nGlobalCount = 0;
        return;
    }

    float flCut = flNow - g_flWindow;

    while (g_nGlobalCount > 0)
    {
        float flOldest = g_flGlobalTimes[g_nGlobalHead];
        if (flOldest >= flCut)
        {
            break;
        }

        g_nGlobalHead = (g_nGlobalHead + 1) % GLOBAL_RING_SIZE;
        g_nGlobalCount--;
    }
}

static void PushGlobal(float flNow)
{
    if (g_nGlobalCount >= GLOBAL_RING_SIZE)
    {
        return;
    }

    int nIdx = (g_nGlobalHead + g_nGlobalCount) % GLOBAL_RING_SIZE;
    g_flGlobalTimes[nIdx] = flNow;
    g_nGlobalCount++;
}

static void ResetState()
{
    for (int i = 0; i <= ENTITY_TRACK_MAX; i++)
    {
        g_flLastEntityTime[i] = 0.0;
    }

    g_nGlobalHead = 0;
    g_nGlobalCount = 0;

    if (g_smSampleLast != null)
    {
        g_smSampleLast.Clear();
    }
}

static void RefreshCvars()
{
    g_bEnable         = g_cvEnable.BoolValue;
    g_nMode           = g_cvMode.IntValue;
    g_nGlobalLimit    = g_cvGlobalLimit.IntValue;
    g_flWindow        = g_cvWindow.FloatValue;
    g_flEntityInterval= g_cvEntityInterval.FloatValue;
    g_flSampleInterval= g_cvSampleInterval.FloatValue;
    g_bSampleMatch    = g_cvSampleMatch.BoolValue;
    g_flScale         = g_cvScale.FloatValue;
    g_flScaleFloor    = g_cvScaleFloor.FloatValue;
    g_bDebug          = g_cvDebug.BoolValue;

    if (g_nMode < 0) { g_nMode = 0; }
    if (g_nMode > 1) { g_nMode = 1; }

    if (g_nGlobalLimit < 0) { g_nGlobalLimit = 0; }
    if (g_flWindow < 0.0) { g_flWindow = 0.0; }
    if (g_flEntityInterval < 0.0) { g_flEntityInterval = 0.0; }
    if (g_flSampleInterval < 0.0) { g_flSampleInterval = 0.0; }

    if (g_flScale < 0.0) { g_flScale = 0.0; }
    if (g_flScale > 1.0) { g_flScale = 1.0; }

    if (g_flScaleFloor < 0.0) { g_flScaleFloor = 0.0; }
    if (g_flScaleFloor > 1.0) { g_flScaleFloor = 1.0; }
}

// ================================================================
// Mid-level
// ================================================================

public void OnConVarChanged(ConVar cv, const char[] oldValue, const char[] newValue)
{
    RefreshCvars();
}

static bool ShouldTreatAsInfectedSource(int nEntity, const char[] sSample)
{
    if (IsEntityInfected(nEntity))
    {
        return true;
    }

    if (g_bSampleMatch && IsSampleLikelyInfected(sSample))
    {
        return true;
    }

    return false;
}

static bool IsThrottledBySample(float flNow, const char[] sSample)
{
    if (g_flSampleInterval <= 0.0)
    {
        return false;
    }

    int nBits;
    if (!g_smSampleLast.GetValue(sSample, nBits))
    {
        return false;
    }

    float flLast = view_as<float>(nBits);
    return ((flNow - flLast) < g_flSampleInterval);
}

// ================================================================
// Entry points
// ================================================================

public Plugin myinfo =
{
    name        = "[L4D2] Infected Sound Throttle",
    author      = "Ren",
    description = "Throttles infected audio spam so it doesn't drown out the game.",
    version     = PLUGIN_VERSION,
    url         = "N/A"
};

public void OnPluginStart()
{
    g_cvEnable         = CreateConVar("l4d2_inf_snd_throttle_enable", "1", "Enable infected sound throttling.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvMode           = CreateConVar("l4d2_inf_snd_throttle_mode", "0", "0=block throttled sounds, 1=scale volume.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvGlobalLimit    = CreateConVar("l4d2_inf_snd_throttle_global_limit", "30", "Max infected sounds per window (0=off).", FCVAR_NOTIFY, true, 0.0);
    g_cvWindow         = CreateConVar("l4d2_inf_snd_throttle_window", "1.0", "Window size in seconds for global_limit.", FCVAR_NOTIFY, true, 0.0);
    g_cvEntityInterval = CreateConVar("l4d2_inf_snd_throttle_entity_interval", "0.06", "Min interval per infected entity (0=off).", FCVAR_NOTIFY, true, 0.0);
    g_cvSampleInterval = CreateConVar("l4d2_inf_snd_throttle_sample_interval", "0.02", "Min interval per sample path (0=off).", FCVAR_NOTIFY, true, 0.0);
    g_cvSampleMatch    = CreateConVar("l4d2_inf_snd_throttle_sample_match", "1", "Also throttle when sample path looks infected even if entity isn't (useful for entity=0).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvScale          = CreateConVar("l4d2_inf_snd_throttle_scale", "0.25", "Volume multiplier in mode=1 when throttled.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvScaleFloor     = CreateConVar("l4d2_inf_snd_throttle_scale_floor", "0.05", "Minimum volume in mode=1 when throttled.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDebug          = CreateConVar("l4d2_inf_snd_throttle_debug", "0", "Debug logging.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

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

    g_smSampleLast = new StringMap();

    RefreshCvars();
    AddNormalSoundHook(NormalSoundHook);
}

public void OnMapStart()
{
    ResetState();
}

public Action NormalSoundHook(
    int clients[64],
    int &numClients,
    char sample[PLATFORM_MAX_PATH],
    int &entity,
    int &channel,
    float &volume,
    int &level,
    int &pitch,
    int &flags
)
{
    if (!g_bEnable)
    {
        return Plugin_Continue;
    }

    if (!ShouldTreatAsInfectedSource(entity, sample))
    {
        return Plugin_Continue;
    }

    float flNow = GetGameTime();
    bool bThrottle = false;

    if (g_nGlobalLimit > 0)
    {
        PruneGlobal(flNow);

        if (g_nGlobalCount >= g_nGlobalLimit)
        {
            bThrottle = true;
        }
    }

    if (!bThrottle && (g_flEntityInterval > 0.0) && (entity > 0) && (entity <= ENTITY_TRACK_MAX))
    {
        float flLast = g_flLastEntityTime[entity];
        if ((flNow - flLast) < g_flEntityInterval)
        {
            bThrottle = true;
        }
    }

    if (!bThrottle && IsThrottledBySample(flNow, sample))
    {
        bThrottle = true;
    }

    if (bThrottle)
    {
        if (g_nMode == 0)
        {
            if (g_bDebug)
            {
                PrintToServer("[InfSndThrottle] BLOCK ent=%d ch=%d vol=%.2f sample=%s", entity, channel, volume, sample);
            }
            return Plugin_Handled;
        }

        float flNewVol = volume * g_flScale;
        if (flNewVol < g_flScaleFloor)
        {
            flNewVol = g_flScaleFloor;
        }
        if (flNewVol < 0.0) { flNewVol = 0.0; }
        if (flNewVol > 1.0) { flNewVol = 1.0; }

        if (g_bDebug)
        {
            PrintToServer("[InfSndThrottle] SCALE ent=%d ch=%d %.2f->%.2f sample=%s", entity, channel, volume, flNewVol, sample);
        }

        volume = flNewVol;
        return Plugin_Changed;
    }

    if (g_nGlobalLimit > 0)
    {
        PushGlobal(flNow);
    }

    if ((g_flEntityInterval > 0.0) && (entity > 0) && (entity <= ENTITY_TRACK_MAX))
    {
        g_flLastEntityTime[entity] = flNow;
    }

    if (g_flSampleInterval > 0.0)
    {
        g_smSampleLast.SetValue(sample, view_as<int>(flNow), true);
    }

    return Plugin_Continue;
}
