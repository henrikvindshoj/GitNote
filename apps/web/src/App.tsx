import {
  useEffect,
  useId,
  useRef,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import {
  BookOpen,
  Plus,
  Folder,
  FileText,
  Search,
  GitBranch,
  RefreshCw,
  Settings,
  ArrowLeft,
  Check,
  CloudOff,
  X,
  Download,
  Trash2,
  ArrowUpRight,
  NotebookPen,
} from "lucide-react";
import {
  addPath,
  changes,
  fileName,
  parentPath,
  repositoryAddress,
  type GitHubUser,
  type Repository,
  type Workspace,
} from "./model";
import { GitHubClient } from "./github";
import { loadWorkspaces, removeWorkspace, saveWorkspace } from "./storage";
import NoteEditor, { downloadText } from "./NoteEditor";

type Modal = "account" | "add" | "note" | "folder" | "sync" | "remove" | null;
function Dialog({
  title,
  children,
  close,
  busy,
}: {
  title: string;
  children: ReactNode;
  close: () => void;
  busy: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  useEffect(() => {
    ref.current?.showModal();
  }, []);
  return (
    <dialog
      ref={ref}
      aria-labelledby={titleId}
      onCancel={(e) => {
        e.preventDefault();
        if (!busy) close();
      }}
    >
      <div className="dialog-heading">
        <h2 id={titleId}>{title}</h2>
        <button
          aria-label="Close dialog"
          className="icon-button"
          disabled={busy}
          onClick={close}
        >
          <X size={20} />
        </button>
      </div>
      {children}
    </dialog>
  );
}

export default function App() {
  const [workspaces, setWorkspaces] = useState<Workspace[]>([]);
  const [selected, setSelected] = useState("");
  const [notePath, setNotePath] = useState("");
  const [directory, setDirectory] = useState("");
  const [query, setQuery] = useState("");
  const [pane, setPane] = useState<"notes" | "changes">("notes");
  const [modal, setModal] = useState<Modal>(null);
  const [token, setToken] = useState("");
  const [tokenInput, setTokenInput] = useState("");
  const [user, setUser] = useState<GitHubUser | null>(null);
  const [repos, setRepos] = useState<Repository[]>([]);
  const [repoQuery, setRepoQuery] = useState("");
  const [address, setAddress] = useState("");
  const [newPath, setNewPath] = useState("");
  const [message, setMessage] = useState("Update notes");
  const [author, setAuthor] = useState("");
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [loaded, setLoaded] = useState(false);
  const [online, setOnline] = useState(navigator.onLine);
  const [saveStatus, setSaveStatus] = useState("Saved on this device");
  const writes = useRef(Promise.resolve());
  const revision = useRef(0);
  const unsaved = useRef(false);
  const failedSaves = useRef(new Set<string>());
  const [hasLock, setHasLock] = useState(false);
  useEffect(() => {
    let active = true;
    let release: (() => void) | undefined;
    const initialize = async () => {
      try {
        const data = await loadWorkspaces();
        if (active) {
          setWorkspaces(data);
          setSelected(data[0]?.id ?? "");
          setLoaded(true);
        }
      } catch {
        if (active)
          setError(
            "Browser storage is unavailable. Enable IndexedDB to use GitNote.",
          );
      }
    };
    if (navigator.locks) {
      void navigator.locks.request(
        "gitnote-workspace-writer",
        { ifAvailable: true },
        async (lock) => {
          if (!active) return;
          if (!lock) {
            setError(
              "GitNote is open in another tab. Close that tab, then reload here to protect your local edits.",
            );
            return;
          }
          setHasLock(true);
          await initialize();
          if (active)
            await new Promise<void>((resolve) => {
              release = resolve;
            });
        },
      );
    } else {
      setHasLock(true);
      void initialize();
    }
    const connection = () => setOnline(navigator.onLine);
    const beforeUnload = (event: BeforeUnloadEvent) => {
      if (unsaved.current) {
        event.preventDefault();
        event.returnValue = "";
      }
    };
    window.addEventListener("online", connection);
    window.addEventListener("offline", connection);
    window.addEventListener("beforeunload", beforeUnload);
    return () => {
      active = false;
      release?.();
      window.removeEventListener("online", connection);
      window.removeEventListener("offline", connection);
      window.removeEventListener("beforeunload", beforeUnload);
    };
  }, []);
  const workspace = workspaces.find((w) => w.id === selected);
  const note = workspace?.notes.find((n) => n.path === notePath);
  const dirty = workspace ? changes(workspace) : [];
  const client = new GitHubClient(token);
  const disabled = !!busy || !loaded || !hasLock;
  function selectWorkspace(id: string) {
    setSelected(id);
    setNotePath("");
    setDirectory("");
    setQuery("");
    setPane("notes");
  }
  function updateWorkspace(next: Workspace) {
    setWorkspaces((current) =>
      [...current.filter((w) => w.id !== next.id), next].sort((a, b) =>
        a.fullName.localeCompare(b.fullName),
      ),
    );
    const version = ++revision.current;
    unsaved.current = true;
    setSaveStatus("Saving…");
    writes.current = writes.current.then(async () => {
      try {
        await saveWorkspace(next);
        failedSaves.current.delete(next.id);
        if (version === revision.current) {
          unsaved.current = failedSaves.current.size > 0;
          setSaveStatus(
            unsaved.current
              ? "Not saved — export your notes"
              : "Saved on this device",
          );
        }
      } catch {
        failedSaves.current.add(next.id);
        setSaveStatus("Not saved — export your notes");
        setError(
          "Could not save to browser storage. Your edits remain on screen. Download or export them before closing this tab.",
        );
      }
    });
  }
  async function run(label: string, action: () => Promise<void>) {
    setBusy(label);
    setError("");
    setNotice("");
    try {
      await action();
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : "Something went wrong. Please try again.",
      );
    } finally {
      setBusy("");
    }
  }
  function openModal(next: Modal) {
    setError("");
    setNewPath("");
    setModal(next);
  }
  async function addRepository(input: string) {
    await run("Downloading repository…", async () => {
      const fullName = repositoryAddress(input);
      if (
        workspaces.some(
          (w) => w.fullName.toLowerCase() === fullName.toLowerCase(),
        )
      )
        throw new Error("This repository is already on this device.");
      const next = await client.download(fullName);
      await saveWorkspace(next);
      setWorkspaces((current) => [...current, next]);
      selectWorkspace(next.id);
      setModal(null);
      setAddress("");
    });
  }
  function createPath(event: FormEvent) {
    event.preventDefault();
    if (!workspace) return;
    try {
      const next = addPath(
        workspace,
        [directory, newPath].filter(Boolean).join("/"),
        modal === "folder",
      );
      updateWorkspace(next);
      if (modal === "note") {
        const created = next.notes.find(
          (n) => !workspace.notes.some((old) => old.path === n.path),
        )!;
        setNotePath(created.path);
      }
      setModal(null);
    } catch (cause) {
      setError((cause as Error).message);
    }
  }
  const localFiles =
    workspace?.notes.filter(
      (n) =>
        parentPath(n.path) === directory &&
        fileName(n.path).toLowerCase().includes(query.toLowerCase()),
    ) ?? [];
  const localDirectories =
    workspace?.directories.filter(
      (p) =>
        parentPath(p) === directory &&
        fileName(p).toLowerCase().includes(query.toLowerCase()),
    ) ?? [];
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <a className="brand" href="/" aria-label="GitNote home">
          <span className="brand-icon">
            <BookOpen size={23} />
          </span>
          GitNote<span className="web-tag">WEB</span>
        </a>
        <div className="sidebar-label">
          WORKING COPIES
          <button
            className="icon-button"
            aria-label="Add repository"
            disabled={disabled}
            onClick={() => openModal("add")}
          >
            <Plus size={17} />
          </button>
        </div>
        <nav className="workspace-list" aria-label="Repositories">
          {workspaces.map((w) => (
            <button
              key={w.id}
              className={`workspace ${w.id === selected ? "active" : ""}`}
              disabled={!!busy}
              onClick={() => selectWorkspace(w.id)}
            >
              <BookOpen size={19} />
              <span>
                <strong>{w.fullName.split("/")[1]}</strong>
                <small>{w.fullName.split("/")[0]}</small>
              </span>
              {changes(w).length > 0 && (
                <span className="badge">{changes(w).length}</span>
              )}
            </button>
          ))}
        </nav>
        {!workspaces.length && (
          <p className="sidebar-hint">
            Your repositories will feel
            <br />
            right at home here.
          </p>
        )}
        <button
          className="add-repository"
          disabled={disabled}
          onClick={() => openModal("add")}
        >
          <Plus size={17} /> Add repository
        </button>
        <div className="sidebar-bottom">
          <div className="local-first">
            {online ? <Check size={15} /> : <CloudOff size={15} />}{" "}
            {online ? "Local first. Yours, always." : "Offline · keep writing"}
          </div>
          <button
            className="account-button"
            disabled={disabled}
            onClick={() => openModal("account")}
          >
            <span className="avatar">
              {user ? (
                user.login.slice(0, 1).toUpperCase()
              ) : (
                <Settings size={18} />
              )}
            </span>
            <span>
              <strong>{user?.login ?? "GitHub account"}</strong>
              <small>
                {user
                  ? "Connected for this session"
                  : "Connect to sync your notes"}
              </small>
            </span>
          </button>
        </div>
      </aside>
      <main>
        <header className="main-header">
          <div>
            <span className="eyebrow">YOUR PERSONAL KNOWLEDGE SPACE</span>
            <h1>
              {workspace
                ? workspace.fullName.split("/")[1]
                : "A little space for big ideas."}
            </h1>
          </div>
          {workspace && (
            <button
              className="primary"
              disabled={disabled || !online || !dirty.length}
              onClick={() => openModal("sync")}
            >
              <RefreshCw size={16} /> Sync changes{" "}
              {dirty.length > 0 && (
                <span className="button-count">{dirty.length}</span>
              )}
            </button>
          )}
        </header>
        {!modal && error && (
          <div className="alert error" role="alert">
            {error}
            <button aria-label="Dismiss error" onClick={() => setError("")}>
              <X size={16} />
            </button>
          </div>
        )}
        {notice && (
          <div className="alert success" role="status">
            {notice}
            <button
              aria-label="Dismiss notification"
              onClick={() => setNotice("")}
            >
              <X size={16} />
            </button>
          </div>
        )}
        {busy && (
          <div className="busy" role="status">
            <RefreshCw className="spin" size={15} />
            {busy}
          </div>
        )}
        {!workspace ? (
          <div className="welcome">
            <div className="welcome-icon">
              <NotebookPen size={40} strokeWidth={1.5} />
            </div>
            <span className="eyebrow">NOTES THAT BELONG TO YOU</span>
            <h2>
              Your words.
              <br />
              Your repositories.
            </h2>
            <p>
              Bring your Markdown notes from GitHub.
              <br />
              Write freely, organize your thoughts, and sync
              <br className="desktop-break" /> when you’re ready.
            </p>
            <button
              className="primary"
              disabled={disabled || !online}
              onClick={() => openModal("add")}
            >
              <Plus size={17} /> Add your first repository
            </button>
            <div className="welcome-features">
              <span>
                <FileText size={16} />
                Plain Markdown
              </span>
              <span>
                <CloudOff size={16} />
                Offline ready
              </span>
              <span>
                <GitBranch size={16} />
                Backed by GitHub
              </span>
            </div>
          </div>
        ) : (
          <>
            <div className="repository-bar">
              <div className="tabs">
                <button
                  className={pane === "notes" ? "selected" : ""}
                  onClick={() => setPane("notes")}
                >
                  <FileText size={16} />
                  Notes <span>{workspace.notes.length}</span>
                </button>
                <button
                  className={pane === "changes" ? "selected" : ""}
                  onClick={() => setPane("changes")}
                >
                  <GitBranch size={16} />
                  Changes <span>{dirty.length}</span>
                </button>
              </div>
              <div className="repo-actions">
                <span className="branch">
                  <GitBranch size={14} />
                  {workspace.branch}
                </span>
                <button
                  className="icon-button"
                  title="Export local notes as JSON"
                  aria-label="Export local notes"
                  onClick={() =>
                    downloadText(
                      `${workspace.fullName.replace("/", "-")}-notes.json`,
                      JSON.stringify(
                        {
                          repository: workspace.fullName,
                          branch: workspace.branch,
                          notes: workspace.notes.map(({ path, content }) => ({
                            path,
                            content,
                          })),
                          directories: workspace.directories,
                        },
                        null,
                        2,
                      ),
                      "application/json",
                    )
                  }
                >
                  <Download size={17} />
                </button>
                <button
                  className="icon-button danger"
                  title="Remove local copy"
                  aria-label="Remove local copy"
                  disabled={disabled}
                  onClick={() => openModal("remove")}
                >
                  <Trash2 size={16} />
                </button>
              </div>
            </div>
            {pane === "notes" ? (
              <div className={`notes-layout ${note ? "has-note" : ""}`}>
                <section className="file-panel" aria-label="Files">
                  <div className="file-controls">
                    <label className="search">
                      <Search size={16} />
                      <input
                        aria-label="Search this folder"
                        placeholder="Search this folder…"
                        value={query}
                        onChange={(e) => setQuery(e.target.value)}
                      />
                    </label>
                    <div className="folder-heading">
                      <button
                        disabled={!directory}
                        onClick={() => {
                          setDirectory(parentPath(directory));
                          setQuery("");
                        }}
                        aria-label="Parent folder"
                      >
                        <ArrowLeft size={15} />
                      </button>
                      <span title={directory}>
                        {directory ? fileName(directory) : "All notes"}
                      </span>
                      <button
                        aria-label="New folder"
                        title="New folder"
                        disabled={disabled}
                        onClick={() => openModal("folder")}
                      >
                        <Folder size={16} />
                      </button>
                      <button
                        aria-label="New note"
                        title="New note"
                        disabled={disabled}
                        onClick={() => openModal("note")}
                      >
                        <Plus size={18} />
                      </button>
                    </div>
                  </div>
                  <div className="file-list">
                    {localDirectories.map((path) => (
                      <button
                        className="file-row folder-row"
                        key={path}
                        onClick={() => {
                          setDirectory(path);
                          setQuery("");
                        }}
                      >
                        <Folder size={18} />
                        <span>{fileName(path)}</span>
                        <span className="chevron">›</span>
                      </button>
                    ))}
                    {localFiles.map((file) => (
                      <button
                        key={file.path}
                        className={`file-row ${file.path === notePath ? "active" : ""}`}
                        disabled={!!busy}
                        onClick={() => setNotePath(file.path)}
                      >
                        <FileText size={17} />
                        <span>
                          {fileName(file.path)}
                          <small>
                            {file.content
                              .replace(/[#*_`>]/g, "")
                              .trim()
                              .slice(0, 60) || "A fresh page, ready for you."}
                          </small>
                        </span>
                        {file.content !== file.base && (
                          <span
                            className="dirty-dot"
                            aria-label="Uncommitted changes"
                          />
                        )}
                      </button>
                    ))}
                    {!localDirectories.length && !localFiles.length && (
                      <div className="file-empty">
                        <FileText size={25} />
                        <p>
                          {query
                            ? "No matching notes or folders."
                            : "A fresh start."}
                        </p>
                        {!query && (
                          <button
                            className="text-button"
                            disabled={disabled}
                            onClick={() => openModal("note")}
                          >
                            Create a note
                          </button>
                        )}
                      </div>
                    )}
                  </div>
                  <footer className="file-footer">
                    {localFiles.length} notes in this folder
                  </footer>
                </section>
                <div className="writing-area">
                  {note ? (
                    <>
                      <button
                        className="mobile-back text-button"
                        onClick={() => setNotePath("")}
                      >
                        <ArrowLeft size={16} />
                        Back to notes
                      </button>
                      <NoteEditor
                        key={`${workspace.id}:${note.path}`}
                        note={note}
                        disabled={disabled}
                        onChange={(content) =>
                          updateWorkspace({
                            ...workspace,
                            notes: workspace.notes.map((n) =>
                              n.path === note.path ? { ...n, content } : n,
                            ),
                          })
                        }
                      />
                    </>
                  ) : (
                    <div className="no-note">
                      <NotebookPen size={37} strokeWidth={1.4} />
                      <h2>Make room for a thought.</h2>
                      <p>Open a note, or start something new.</p>
                      <button
                        className="text-button"
                        disabled={disabled}
                        onClick={() => openModal("note")}
                      >
                        <Plus size={16} />
                        New note
                      </button>
                    </div>
                  )}
                </div>
              </div>
            ) : (
              <section className="changes-pane">
                <div className="changes-heading">
                  <h2>
                    {dirty.length
                      ? "Ready when you are."
                      : "Everything is up to date."}
                  </h2>
                  <p>
                    {dirty.length
                      ? `${dirty.length} changed ${dirty.length === 1 ? "file" : "files"} waiting to be committed to ${workspace.branch}.`
                      : "Your working copy has no uncommitted changes."}
                  </p>
                </div>
                {dirty.map((n) => (
                  <details key={n.path}>
                    <summary>
                      <span
                        className={`change-kind ${n.base === null ? "added" : ""}`}
                      >
                        {n.base === null ? "A" : "M"}
                      </span>
                      <strong>{n.path}</strong>
                      <span className="muted">
                        {n.base === null ? "Added" : "Modified"}
                      </span>
                    </summary>
                    <div className="diff">
                      <div>
                        <h3>Before</h3>
                        <pre>{n.base ?? "(New file)"}</pre>
                      </div>
                      <div>
                        <h3>After</h3>
                        <pre>{n.content || "(Empty file)"}</pre>
                      </div>
                    </div>
                  </details>
                ))}
                <p className="changes-note">
                  Sync commits all changed notes. It does not pull or merge
                  remote changes. Empty folders stay local until they contain a
                  committed note.
                </p>
              </section>
            )}
            <footer className="status-bar">
              <span>
                <span
                  className={
                    saveStatus.startsWith("Saved") ? "status-dot" : "dirty-dot"
                  }
                />
                {saveStatus}
              </span>
              <a
                href={`https://github.com/${workspace.fullName}`}
                target="_blank"
                rel="noreferrer"
              >
                View on GitHub <ArrowUpRight size={13} />
              </a>
            </footer>
          </>
        )}
      </main>
      {modal && (
        <Dialog
          title={
            {
              account: "GitHub account",
              add: "Add a repository",
              note: "New Markdown note",
              folder: "New folder",
              sync: "Sync changes",
              remove: "Remove local copy?",
            }[modal]
          }
          busy={!!busy}
          close={() => {
            setModal(null);
            setError("");
          }}
        >
          {error && (
            <p className="alert error" role="alert">
              {error}
            </p>
          )}
          {modal === "account" && (
            <>
              {user ? (
                <>
                  <p>
                    Connected as <strong>{user.login}</strong>. Your token is
                    held in memory and cleared when this page closes or reloads.
                  </p>
                  <button
                    className="secondary"
                    disabled={!!busy}
                    onClick={() => {
                      setToken("");
                      setUser(null);
                      setRepos([]);
                      setModal(null);
                    }}
                  >
                    Disconnect GitHub
                  </button>
                  <p className="muted">
                    Downloaded repositories remain on this browser after
                    disconnecting.
                  </p>
                </>
              ) : (
                <form
                  onSubmit={(event) => {
                    event.preventDefault();
                    void run("Connecting to GitHub…", async () => {
                      const nextToken = tokenInput.trim();
                      const api = new GitHubClient(nextToken);
                      const account = await api.user();
                      setToken(nextToken);
                      setTokenInput("");
                      setUser(account);
                      setAuthor(account.login);
                      setEmail(
                        `${account.id}+${account.login}@users.noreply.github.com`,
                      );
                      setModal(null);
                      setNotice(`Connected as ${account.login}.`);
                    });
                  }}
                >
                  <p>
                    Connect with a fine-grained personal access token. Give
                    selected repositories{" "}
                    <strong>Contents: Read and write</strong> access to sync, or
                    read access to browse.
                  </p>
                  <label>
                    Personal access token
                    <input
                      type="password"
                      autoComplete="off"
                      required
                      value={tokenInput}
                      onChange={(e) => setTokenInput(e.target.value)}
                      placeholder="github_pat_…"
                    />
                  </label>
                  <p className="muted">
                    Your token stays in memory for this session. It is never
                    saved in browser storage.
                  </p>
                  <a
                    className="text-button"
                    href="https://github.com/settings/personal-access-tokens/new"
                    target="_blank"
                    rel="noreferrer"
                  >
                    Create a token on GitHub <ArrowUpRight size={14} />
                  </a>
                  <div className="dialog-actions">
                    <button
                      className="primary"
                      disabled={!!busy || !online || !tokenInput.trim()}
                    >
                      Connect account
                    </button>
                  </div>
                </form>
              )}
            </>
          )}
          {modal === "add" && (
            <>
              <p>
                Download a Markdown repository for offline writing. Public
                repositories work without connecting an account.
              </p>
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  void addRepository(address);
                }}
              >
                <label>
                  Repository address
                  <input
                    autoFocus
                    required
                    placeholder="owner/repository or GitHub URL"
                    value={address}
                    onChange={(e) => setAddress(e.target.value)}
                  />
                </label>
                <div className="dialog-actions">
                  <button className="primary" disabled={!!busy || !online}>
                    Add repository
                  </button>
                </div>
              </form>
              <div className="discovery">
                <h3>Your GitHub repositories</h3>
                {user ? (
                  <>
                    <button
                      className="text-button"
                      disabled={!!busy || !online}
                      onClick={() =>
                        void run("Loading repositories…", async () =>
                          setRepos(await client.repositories()),
                        )
                      }
                    >
                      <RefreshCw size={14} />
                      Load repositories
                    </button>
                    <input
                      aria-label="Filter GitHub repositories"
                      placeholder="Filter repositories…"
                      value={repoQuery}
                      onChange={(e) => setRepoQuery(e.target.value)}
                    />
                    <div className="remote-list">
                      {repos
                        .filter((r) =>
                          r.full_name
                            .toLowerCase()
                            .includes(repoQuery.toLowerCase()),
                        )
                        .map((r) => (
                          <button
                            key={r.id}
                            disabled={
                              !!busy ||
                              !online ||
                              workspaces.some((w) => w.id === String(r.id))
                            }
                            onClick={() => void addRepository(r.full_name)}
                          >
                            <BookOpen size={17} />
                            <span>
                              {r.full_name}
                              <small>{r.private ? "Private" : "Public"}</small>
                            </span>
                            <Plus size={16} />
                          </button>
                        ))}
                    </div>
                  </>
                ) : (
                  <button
                    className="text-button"
                    onClick={() => openModal("account")}
                  >
                    Connect an account to find private repositories{" "}
                    <ArrowUpRight size={14} />
                  </button>
                )}
              </div>
            </>
          )}
          {(modal === "note" || modal === "folder") && (
            <form onSubmit={createPath}>
              <p>
                Create in <strong>{directory || "the repository root"}</strong>.
                Nested paths are supported.
              </p>
              <label>
                {modal === "note" ? "Note path" : "Folder path"}
                <input
                  autoFocus
                  required
                  placeholder={
                    modal === "note" ? "ideas/a-new-thought.md" : "ideas"
                  }
                  value={newPath}
                  onChange={(e) => setNewPath(e.target.value)}
                />
              </label>
              <p className="muted">
                {modal === "note"
                  ? "A missing extension becomes .md. Notes save automatically on this device."
                  : "Empty folders stay on this device until they contain a committed file."}
              </p>
              <div className="dialog-actions">
                <button
                  className="primary"
                  disabled={disabled || !newPath.trim()}
                >
                  Create {modal === "note" ? "note" : "folder"}
                </button>
              </div>
            </form>
          )}
          {modal === "sync" && workspace && (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                void run("Committing and syncing…", async () => {
                  await writes.current;
                  if (unsaved.current)
                    throw new Error(
                      "Save or export your local edits before syncing.",
                    );
                  const next = await client.sync(
                    workspace,
                    message,
                    author,
                    email,
                  );
                  updateWorkspace(next);
                  await writes.current;
                  setModal(null);
                  setNotice(
                    `Synced ${dirty.length} ${dirty.length === 1 ? "note" : "notes"} to GitHub. Commit ${next.head.slice(0, 8)}.`,
                  );
                });
              }}
            >
              <p>
                Create one commit with all{" "}
                <strong>{dirty.length} changed notes</strong> and update{" "}
                <strong>{workspace.branch}</strong>. Remote changes will never
                be overwritten.
              </p>
              {!user && (
                <p className="alert">
                  Connect your GitHub account before syncing.{" "}
                  <button
                    type="button"
                    className="text-button"
                    onClick={() => openModal("account")}
                  >
                    Open account
                  </button>
                </p>
              )}
              <label>
                Commit message
                <input
                  required
                  value={message}
                  onChange={(e) => setMessage(e.target.value)}
                />
              </label>
              <label>
                Author name
                <input
                  required
                  value={author}
                  onChange={(e) => setAuthor(e.target.value)}
                />
              </label>
              <label>
                Author email
                <input
                  required
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                />
              </label>
              <div className="dialog-actions">
                <button
                  className="primary"
                  disabled={!!busy || !online || !user || !dirty.length}
                >
                  <RefreshCw size={16} />
                  Commit and sync
                </button>
              </div>
            </form>
          )}
          {modal === "remove" && workspace && (
            <>
              <p>
                This removes <strong>{workspace.fullName}</strong> from this
                browser. The GitHub repository stays as it is.
              </p>
              {dirty.length > 0 && (
                <p className="alert error">
                  {dirty.length} uncommitted{" "}
                  {dirty.length === 1 ? "note will" : "notes will"} be lost.
                  Export your notes before removing this copy.
                </p>
              )}
              <div className="dialog-actions">
                <button
                  className="secondary"
                  disabled={!!busy}
                  onClick={() => setModal(null)}
                >
                  Keep local copy
                </button>
                <button
                  className="destructive"
                  disabled={!!busy}
                  onClick={() =>
                    void run("Removing local copy…", async () => {
                      await writes.current;
                      await removeWorkspace(workspace.id);
                      failedSaves.current.delete(workspace.id);
                      unsaved.current = failedSaves.current.size > 0;
                      setSaveStatus(
                        unsaved.current
                          ? "Not saved — export your notes"
                          : "Saved on this device",
                      );
                      setWorkspaces((current) =>
                        current.filter((w) => w.id !== workspace.id),
                      );
                      selectWorkspace(
                        workspaces.find((w) => w.id !== workspace.id)?.id ?? "",
                      );
                      setModal(null);
                    })
                  }
                >
                  Remove local copy
                </button>
              </div>
            </>
          )}
        </Dialog>
      )}
    </div>
  );
}
