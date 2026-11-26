import { constants as fsConstants } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { createHash, type Hash } from "node:crypto";
import type { AdapterExecutionContext } from "@paperclipai/adapter-utils";
import {
  ensurePaperclipSkillSymlink,
  resolvePaperclipInstanceRootForAdapter,
  type PaperclipSkillEntry,
} from "@paperclipai/adapter-utils/server-utils";

type SkillEntry = PaperclipSkillEntry;

export interface ClaudePromptBundle {
  bundleKey: string;
  rootDir: string;
  addDir: string;
  instructionsFilePath: string | null;
}

function nonEmpty(value: string | undefined): string | null {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
}

function resolveManagedClaudePromptCacheRoot(
  env: NodeJS.ProcessEnv,
  companyId: string,
): string {
  const instanceRoot = resolvePaperclipInstanceRootForAdapter({
    homeDir: nonEmpty(env.PAPERCLIP_HOME) ?? undefined,
    instanceId: nonEmpty(env.PAPERCLIP_INSTANCE_ID) ?? undefined,
    env,
  });
  return path.resolve(
    instanceRoot,
    "companies",
    companyId,
    "claude-prompt-cache",
  );
}

async function hashPathContents(
  candidate: string,
  hash: Hash,
  relativePath: string,
  seenDirectories: Set<string>,
): Promise<void> {
  const stat = await fs.lstat(candidate);

  if (stat.isSymbolicLink()) {
    hash.update(`symlink:${relativePath}\n`);
    const resolved = await fs.realpath(candidate).catch(() => null);
    if (!resolved) {
      hash.update("missing\n");
      return;
    }
    await hashPathContents(resolved, hash, relativePath, seenDirectories);
    return;
  }

  if (stat.isDirectory()) {
    const realDir = await fs.realpath(candidate).catch(() => candidate);
    hash.update(`dir:${relativePath}\n`);
    if (seenDirectories.has(realDir)) {
      hash.update("loop\n");
      return;
    }
    seenDirectories.add(realDir);
    const entries = await fs.readdir(candidate, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const childRelativePath = relativePath.length > 0 ? `${relativePath}/${entry.name}` : entry.name;
      await hashPathContents(path.join(candidate, entry.name), hash, childRelativePath, seenDirectories);
    }
    return;
  }

  if (stat.isFile()) {
    hash.update(`file:${relativePath}\n`);
    hash.update(await fs.readFile(candidate));
    hash.update("\n");
    return;
  }

  hash.update(`other:${relativePath}:${stat.mode}\n`);
}

async function buildClaudePromptBundleKey(input: {
  skills: SkillEntry[];
  instructionsContents: string | null;
}): Promise<string> {
  const hash = createHash("sha256");
  hash.update("paperclip-claude-prompt-bundle:v1\n");
  if (input.instructionsContents) {
    hash.update("instructions\n");
    hash.update(input.instructionsContents);
    hash.update("\n");
  } else {
    hash.update("instructions:none\n");
  }

  const sortedSkills = [...input.skills].sort((left, right) => left.runtimeName.localeCompare(right.runtimeName));
  for (const entry of sortedSkills) {
    hash.update(`skill:${entry.key}:${entry.runtimeName}\n`);
    await hashPathContents(entry.source, hash, entry.runtimeName, new Set<string>());
  }

  return hash.digest("hex");
}

async function ensureReadableFile(targetPath: string, contents: string): Promise<void> {
  try {
    await fs.access(targetPath, fsConstants.R_OK);
    return;
  } catch {
    // Fall through and materialize the file.
  }

  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  const tempPath = `${targetPath}.${process.pid}.${Date.now()}.tmp`;
  try {
    await fs.writeFile(tempPath, contents, "utf8");
    await fs.rename(tempPath, targetPath);
  } catch (err) {
    const targetReadable = await fs.access(targetPath, fsConstants.R_OK).then(() => true).catch(() => false);
    if (!targetReadable) {
      throw err;
    }
  } finally {
    await fs.rm(tempPath, { force: true }).catch(() => {});
  }
}

export async function prepareClaudePromptBundle(input: {
  companyId: string;
  skills: SkillEntry[];
  instructionsContents: string | null;
  onLog: AdapterExecutionContext["onLog"];
}): Promise<ClaudePromptBundle> {
  const { companyId, skills, instructionsContents, onLog } = input;
  const bundleKey = await buildClaudePromptBundleKey({
    skills,
    instructionsContents,
  });
  const rootDir = path.join(resolveManagedClaudePromptCacheRoot(process.env, companyId), bundleKey);
  const skillsHome = path.join(rootDir, ".claude", "skills");
  await fs.mkdir(skillsHome, { recursive: true });

  for (const entry of skills) {
    const target = path.join(skillsHome, entry.runtimeName);
    try {
      await ensurePaperclipSkillSymlink(entry.source, target);
    } catch (err) {
      await onLog(
        "stderr",
        `[paperclip] Failed to materialize Claude skill "${entry.key}" into ${skillsHome}: ${err instanceof Error ? err.message : String(err)}\n`,
      );
    }
  }

  const instructionsFilePath = instructionsContents
    ? path.join(rootDir, "agent-instructions.md")
    : null;
  if (instructionsFilePath && instructionsContents) {
    await ensureReadableFile(instructionsFilePath, instructionsContents);
  }

  return {
    bundleKey,
    rootDir,
    addDir: rootDir,
    instructionsFilePath,
  };
}

const RUNTIME_NAME_HASH_SUFFIX = /--[0-9a-f]{8,}$/;

/**
 * Chooses the user-scope directory name for each bundled skill. The name is
 * the runtime name without its `--<hash>` suffix, so `Skill <slug>` resolves.
 * When two skills would get the same clean name, or a clean name matches
 * another skill's runtime name, those skills keep their runtime names.
 */
export function resolveClaudeUserScopeSkillNames(skills: SkillEntry[]): Map<string, string> {
  const cleanName = (entry: SkillEntry) => entry.runtimeName.replace(RUNTIME_NAME_HASH_SUFFIX, "") || entry.runtimeName;
  const counts = new Map<string, number>();
  for (const entry of skills) counts.set(cleanName(entry), (counts.get(cleanName(entry)) ?? 0) + 1);
  const runtimeNames = new Set(skills.map((entry) => entry.runtimeName));
  const names = new Map<string, string>();
  for (const entry of skills) {
    const clean = cleanName(entry);
    const ambiguous = (counts.get(clean) ?? 0) > 1 || (clean !== entry.runtimeName && runtimeNames.has(clean));
    names.set(entry.runtimeName, ambiguous ? entry.runtimeName : clean);
  }
  return names;
}

/**
 * Claude Code loads `--add-dir` skills as project scope. Managed AI connection
 * runs pass `--setting-sources user`, which drops project scope, so the
 * bundled company skills never reach the Skill tool. Link each bundled skill
 * into `<CLAUDE_CONFIG_DIR>/skills` (user scope) instead of loading project
 * settings from the workspace. Links point at the bundle entries, and stale
 * links into the prompt cache from an earlier bundle are removed.
 */
export async function linkClaudePromptBundleSkillsIntoUserScope(input: {
  bundle: ClaudePromptBundle;
  claudeConfigDir: string;
  skills: SkillEntry[];
  onLog: AdapterExecutionContext["onLog"];
}): Promise<string[]> {
  const { bundle, claudeConfigDir, skills, onLog } = input;
  const bundleSkillsHome = path.join(bundle.rootDir, ".claude", "skills");
  const userSkillsHome = path.join(claudeConfigDir, "skills");
  const promptCacheRoot = path.dirname(bundle.rootDir);
  await fs.mkdir(userSkillsHome, { recursive: true });

  const desired = new Map<string, string>();
  for (const [runtimeName, name] of resolveClaudeUserScopeSkillNames(skills)) {
    desired.set(name, path.join(bundleSkillsHome, runtimeName));
  }

  for (const entry of await fs.readdir(userSkillsHome, { withFileTypes: true })) {
    if (!entry.isSymbolicLink()) continue;
    const linkPath = path.join(userSkillsHome, entry.name);
    const linked = await fs.readlink(linkPath).catch(() => null);
    if (!linked) continue;
    const resolved = path.resolve(userSkillsHome, linked);
    const ownedByPromptCache = resolved.startsWith(`${promptCacheRoot}${path.sep}`);
    if (ownedByPromptCache && desired.get(entry.name) !== resolved) await fs.unlink(linkPath);
  }

  const linked: string[] = [];
  for (const [name, source] of desired) {
    const target = path.join(userSkillsHome, name);
    try {
      const outcome = await ensurePaperclipSkillSymlink(source, target);
      if (outcome === "skipped" && (await fs.readlink(target).catch(() => null)) !== source) {
        await onLog(
          "stderr",
          `[paperclip] Claude user skill "${name}" already exists in ${userSkillsHome}; leaving it in place.\n`,
        );
        continue;
      }
      linked.push(name);
    } catch (err) {
      await onLog(
        "stderr",
        `[paperclip] Failed to link Claude skill "${name}" into ${userSkillsHome}: ${err instanceof Error ? err.message : String(err)}\n`,
      );
    }
  }
  return linked.sort();
}
