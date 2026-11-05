import { t } from "./i18n";

export const personRelationships = [
  "孩子",
  "爸爸",
  "妈妈",
  "爷爷",
  "奶奶",
  "外公",
  "外婆",
  "哥哥",
  "姐姐",
  "弟弟",
  "妹妹",
  "朋友",
];
export const petSpecies = ["猫", "狗", "兔子", "鸟", "鱼", "仓鼠", "乌龟"];

export function profileCategories(profiles: any[]) {
  const species = [
    ...new Set(
      profiles
        .filter((p) => p.profile_type === "pet" && p.species)
        .map((p) => p.species as string),
    ),
  ];
  return [
    { value: "", label: t("全部分类") },
    { value: "people", label: t("人物") },
    { value: "pets", label: t("宠物") },
    ...species.map((name) => ({
      value: "species:" + name,
      label: t("宠物") + " · " + t(name),
    })),
    ...(profiles.some((p) => p.profile_type === "pet" && !p.species)
      ? [{ value: "uncategorized", label: t("宠物 · 未分类") }]
      : []),
  ];
}

export function matchesProfile(profile: any, category: string, search: string) {
  const pet = profile.profile_type === "pet";
  const matchesCategory =
    !category ||
    (category === "people" && !pet) ||
    (category === "pets" && pet) ||
    (category === "uncategorized" && pet && !profile.species) ||
    (category.startsWith("species:") &&
      pet &&
      profile.species === category.slice(8));
  const relationship =
    profile.relationship ||
    (profile.profile_type === "child" || !profile.profile_type ? "孩子" : "");
  return (
    matchesCategory &&
    [
      profile.name,
      profile.nickname,
      relationship,
      t(relationship),
      profile.species,
      t(profile.species || ""),
      profile.breed,
    ]
      .join(" ")
      .toLocaleLowerCase()
      .includes(search.trim().toLocaleLowerCase())
  );
}

export function hasGrowthTimeline(profile: any): boolean {
  if (!profile) return false;
  return (
    profile.growth_enabled ??
    (!profile.profile_type ||
      profile.profile_type === "child" ||
      profile.profile_type === "pet" ||
      profile.relationship === "孩子")
  );
}
