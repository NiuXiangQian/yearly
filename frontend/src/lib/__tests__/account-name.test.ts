import { expect, it } from "vitest";
import { accountName } from "../accounts";

it("prefers a nickname and falls back to the unchanged login username", () => {
  expect(accountName({ username: "family-login", nickname: "小禾爸爸" })).toBe("小禾爸爸");
  expect(accountName({ username: "family-login", nickname: "" })).toBe("family-login");
  expect(accountName({ username: "family-login" })).toBe("family-login");
});
