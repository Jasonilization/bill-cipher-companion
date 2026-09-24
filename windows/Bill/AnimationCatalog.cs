// GENERATED from BillSpriteCatalog.swift via the build manifest — every
// sprite family with its authentic frame duration (AnimationClipLibrary's
// own pacing). Do not hand-edit.
using System.Linq;
namespace Bill;

public enum AnimGroup { Core, Rare, Dock, Movement }

public record AnimFamily(string Name, string Prefix, int FrameCount, int FrameMs, AnimGroup Group);

public static class AnimationCatalog
{
    public static readonly AnimFamily[] All = new AnimFamily[]
    {
        new("idle", "bill_idle", 7, 150, AnimGroup.Core),
        new("walk", "bill_walk", 6, 140, AnimGroup.Core),
        new("annoyed", "bill_annoyed", 6, 160, AnimGroup.Core),
        new("happy", "bill_happy", 2, 160, AnimGroup.Core),
        new("confused", "bill_confused", 4, 180, AnimGroup.Core),
        new("heating", "bill_heating", 7, 140, AnimGroup.Core),
        new("charging", "bill_charging", 1, 140, AnimGroup.Core),
        new("surprised", "bill_surprised", 3, 180, AnimGroup.Core),
        new("poked", "bill_poked", 4, 110, AnimGroup.Core),
        new("dazed", "bill_dazed", 2, 220, AnimGroup.Core),
        new("sleeping", "bill_sleeping", 1, 140, AnimGroup.Core),
        new("thinking", "bill_thinking", 4, 350, AnimGroup.Core),
        new("coding", "bill_coding", 2, 220, AnimGroup.Core),
        new("talking", "bill_talking", 3, 150, AnimGroup.Core),
        new("smug", "bill_smug", 2, 200, AnimGroup.Core),
        new("snap", "bill_snap", 3, 140, AnimGroup.Core),
        new("focused", "bill_focused", 4, 200, AnimGroup.Core),
        new("channeling", "bill_channeling", 9, 150, AnimGroup.Core),
        new("celebrating", "bill_celebrating", 5, 140, AnimGroup.Core),
        new("curious", "bill_curious", 4, 140, AnimGroup.Core),
        new("cane", "bill_cane", 8, 140, AnimGroup.Core),
        new("powerSurge", "bill_powersurge", 4, 90, AnimGroup.Rare),
        new("powerSurgeClose", "bill_powersurgeclose", 1, 140, AnimGroup.Rare),
        new("portalRing", "bill_portalring", 8, 140, AnimGroup.Rare),
        new("zodiac", "bill_zodiac", 8, 140, AnimGroup.Rare),
        new("summonRitual", "bill_summonritual", 4, 250, AnimGroup.Rare),
        new("ghost", "bill_ghost", 8, 140, AnimGroup.Rare),
        new("glitch", "bill_glitch", 4, 140, AnimGroup.Rare),
        new("shadowA", "bill_shadowa", 5, 140, AnimGroup.Rare),
        new("shadowB", "bill_shadowb", 4, 140, AnimGroup.Rare),
        new("meltdown", "bill_meltdown", 8, 150, AnimGroup.Rare),
        new("trickster", "bill_trickster", 8, 150, AnimGroup.Dock),
        new("darkWorld", "bill_darkworld", 9, 170, AnimGroup.Dock),
        new("hollowed", "bill_hollowed", 11, 160, AnimGroup.Dock),
        new("cultLeader", "bill_cultleader", 8, 170, AnimGroup.Dock),
        new("spooked", "bill_spooked", 5, 130, AnimGroup.Dock),
        new("scanning", "bill_scanning", 8, 130, AnimGroup.Dock),
        new("sneaking", "bill_sneaking", 6, 140, AnimGroup.Dock),
        new("glitching", "bill_glitching", 4, 140, AnimGroup.Dock),
        new("charged", "bill_charged", 6, 140, AnimGroup.Dock),
        new("transferring", "bill_transferring", 12, 90, AnimGroup.Dock),
        new("summoning", "bill_summoning", 8, 140, AnimGroup.Dock),
        new("sculpting", "bill_sculpting", 14, 160, AnimGroup.Dock),
        new("kinship", "bill_kinship", 5, 130, AnimGroup.Dock),
        new("fractaling", "bill_fractaling", 3, 200, AnimGroup.Dock),
        new("presenting", "bill_presenting", 3, 170, AnimGroup.Dock),
        new("guilty", "bill_guilty", 3, 200, AnimGroup.Dock),
        new("dreading", "bill_dreading", 4, 160, AnimGroup.Dock),
        new("grooving", "bill_grooving", 3, 150, AnimGroup.Dock),
        new("dispatching", "bill_dispatching", 4, 140, AnimGroup.Dock),
        new("ambushed", "bill_ambushed", 8, 130, AnimGroup.Dock),
        new("stressed", "bill_stressed", 7, 160, AnimGroup.Dock),
        new("watched", "bill_watched", 5, 160, AnimGroup.Dock),
        new("flinching", "bill_flinching", 3, 130, AnimGroup.Dock),
        new("huffy", "bill_huffy", 6, 110, AnimGroup.Dock),
        new("pushingCode", "bill_pushingcode", 6, 100, AnimGroup.Dock),
        new("browsingStore", "bill_browsingstore", 3, 100, AnimGroup.Dock),
        new("dancing", "bill_dancing", 7, 120, AnimGroup.Dock),
        new("caneTwist", "bill_canetwist", 8, 130, AnimGroup.Movement),
        new("hookCane", "bill_hookcane", 5, 180, AnimGroup.Movement),
        new("conjuring", "bill_conjuring", 18, 150, AnimGroup.Movement),
        new("tumbling", "bill_tumbling", 4, 150, AnimGroup.Movement),
        new("dashTarget", "bill_dashtarget", 4, 110, AnimGroup.Movement),
        new("grumpEyes", "bill_grumpeyes", 6, 150, AnimGroup.Movement),
        new("zipAround", "bill_ziparound", 11, 110, AnimGroup.Movement),
        new("rampaging", "bill_rampaging", 10, 110, AnimGroup.Movement),
    };

    public static AnimFamily? ByName(string name) => All.FirstOrDefault(f => f.Name == name);
}
