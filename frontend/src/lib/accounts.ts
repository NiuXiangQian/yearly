export function accountName(account?: { nickname?: string; username?: string } | null) {
  return account?.nickname || account?.username || "";
}
