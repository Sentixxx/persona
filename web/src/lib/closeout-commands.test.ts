import { describe, expect, it } from "vitest";
import { closeoutCommandClaims, closeoutCommandEvidence } from "./closeout-commands";
import { segments, type Segment } from "./turns";
import type { Item, TaskNote } from "./types";

let seq = 0;
function item(kind: Item["kind"], extra: Partial<Item> = {}): Item {
  seq++;
  return { id: `i${seq}#0`, seq, role: kind === "tool_result" ? "user" : "assistant", kind, ...extra };
}

function exchange(commands: { command: string; result?: Partial<Item>; note?: TaskNote }[]): Segment {
  const items: Item[] = [item("text", { role: "user", text: "Check it" })];
  commands.forEach(({ command, result, note }, i) => {
    const call = `call-${seq}-${i}`;
    items.push(item("tool_use", { tool_use_id: call, tool_name: "Bash", tool_input: { command } }));
    if (result) items.push(item("tool_result", { tool_use_id: call, text: "recorded output", ...result }));
    if (note) items.push(item("notice", { tool_use_id: call, task: note }));
  });
  items.push(item("text", { text: "Done" }));
  return segments(items)[0];
}

describe("closeoutCommandClaims", () => {
  it("reads inline code and recognizable bare commands, not prose or echo text", () => {
    expect(closeoutCommandClaims("Ran `cd web && npm test` and `GOFLAGS=-count=1 go test ./...`.")).toEqual(["cd web && npm test", "GOFLAGS=-count=1 go test ./..."]);
    expect(closeoutCommandClaims("npm test passed; python3 scripts/privacy_check.py 12/12 passed")).toEqual(["npm test", "python3 scripts/privacy_check.py"]);
    expect(closeoutCommandClaims("make sure this works; go to the tests; `echo go test ./...`")).toEqual([]);
    expect(closeoutCommandClaims("echo go test ./...")).toEqual([]);
    expect(closeoutCommandClaims("`cat <<EOF\ngo test ./...\nEOF`")).toEqual([]);
  });

  it("unwraps a shell only to recognize a command, preserving the claim as written", () => {
    expect(closeoutCommandClaims("`bash -lc 'CI=1 npm test'`")).toEqual(["bash -lc 'CI=1 npm test'"]);
    expect(closeoutCommandClaims("`go test -run 'TestA|TestB' ./...`")).toEqual(["go test -run 'TestA|TestB' ./..."]);
  });
});

describe("closeoutCommandEvidence matching", () => {
  it.each([
    ["cd pkg && GOFLAGS=-count=1 go test ./... -race", true],
    ["go test ./... -v", true],
    ["bash -lc 'cd web && CI=1 npm test'", false],
    ["go test ./internal/...", false],
    ["go test ./... -run TestFoo", false],
    ["go test ./... --run=TestFoo", false],
    ["go test ./... -run TestFoo -v", false],
    ['echo "go test ./..."', false],
    ["cat <<EOF\ngo test ./...\nEOF", false],
  ])("go test ./... against %s => %s", (command, found) => {
    const result = closeoutCommandEvidence("`go test ./...`", exchange([{ command, result: { is_error: false } }]))[0];
    expect(result.state === "not_found").toBe(!found);
  });

  it("matches npm test through a shell wrapper, environment, directory change and output redirection", () => {
    const command = "env -i CI=1 timeout 30s bash -lc 'cd web && npm test 2>&1 | tail -n 5'";
    const result = closeoutCommandEvidence("`cd web && npm test`", exchange([{ command, result: { is_error: false } }]))[0];
    expect(result.state).toBe("error");
    expect(result.command).toBe(command);
  });

  it("rejects a different npm test selection and reversed command order", () => {
    for (const command of ["npm test -- src/one.test.ts", "npm test --testNamePattern=one", "npm test --runTestsByPath=src/one.test.ts"]) {
      expect(closeoutCommandEvidence("`npm test`", exchange([{ command, result: { is_error: false } }]))[0].state).toBe("not_found");
    }
    expect(closeoutCommandEvidence("`npm test`", exchange([{ command: "npm test -- --runInBand", result: { is_error: false } }]))[0].state).toBe("error");
    expect(closeoutCommandEvidence("`go vet ./... && go test ./...`", exchange([{ command: "go test ./... && go vet ./...", result: { is_error: false } }]))[0].state).toBe("not_found");
  });

  it("does not borrow another exchange's command", () => {
    const earlier = exchange([{ command: "npm test", result: { is_error: false } }]);
    const later = exchange([{ command: "npm run build", result: { is_error: false } }]);
    expect(earlier.id).not.toBe(later.id);
    expect(closeoutCommandEvidence("`npm test`", later)[0].state).toBe("not_found");
  });
});

describe("closeoutCommandEvidence facts", () => {
  it("shows a numeric zero without turning an error flag into an exit code", () => {
    const zero = closeoutCommandEvidence("`npm test`", exchange([{ command: "npm test", result: { is_error: false, outcome: { status: "ok", exit_code: 0 } } }]))[0];
    expect(zero).toMatchObject({ state: "exit", exitCode: 0, isError: false });
    const flag = closeoutCommandEvidence("`npm test`", exchange([{ command: "npm test", result: { is_error: false } }]))[0];
    expect(flag).toMatchObject({ state: "error", isError: false });
    expect(flag.exitCode).toBeUndefined();
  });

  it("shows a nonzero exit and the error flag together", () => {
    const result = closeoutCommandEvidence("`go test ./...`", exchange([{ command: "go test ./...", result: { is_error: true, outcome: { status: "failed", exit_code: 2 } } }]))[0];
    expect(result).toMatchObject({ state: "exit", exitCode: 2, isError: true });
  });

  it("distinguishes background, running and a later numeric background result", () => {
    const background = closeoutCommandEvidence("`npm test`", exchange([{ command: "npm test", result: { is_error: false, outcome: { status: "background" } } }]))[0];
    expect(background).toMatchObject({ state: "background", background: true, isError: false });
    const running = closeoutCommandEvidence("`npm test`", exchange([{ command: "npm test", result: { is_error: false, outcome: { status: "background" } }, note: { kind: "shell", status: "running" } }]))[0];
    expect(running).toMatchObject({ state: "running", background: true });
    const done = closeoutCommandEvidence("`npm test`", exchange([{ command: "npm test", result: { is_error: false, outcome: { status: "background" } }, note: { kind: "shell", status: "completed", exit_code: 0 } }]))[0];
    expect(done).toMatchObject({ state: "exit", background: true, exitCode: 0 });
  });

  it("keeps a call without a result and a folded segment unavailable, not not-found", () => {
    expect(closeoutCommandEvidence("`npm test`", exchange([{ command: "npm test" }]))[0]).toMatchObject({ state: "unavailable", reason: "no_result" });
    const folded = exchange([{ command: "npm test", result: { is_error: false } }]);
    folded.folds = [item("fold")];
    expect(closeoutCommandEvidence("`npm test`", folded)[0].state).toBe("unavailable");
    expect(closeoutCommandEvidence("`npm test`", undefined)[0].state).toBe("unavailable");
  });

  it("keeps known facts beside a truncated record without presenting it as complete evidence", () => {
    const result = closeoutCommandEvidence("`npm test`", exchange([{ command: "npm test", result: { is_error: true, full_size: 9000, outcome: { status: "failed", exit_code: 1 } } }]))[0];
    expect(result).toMatchObject({ state: "unavailable", reason: "truncated", exitCode: 1, isError: true });
  });
});
