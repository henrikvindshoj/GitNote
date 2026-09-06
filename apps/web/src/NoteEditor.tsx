import { useEffect, useState } from "react";
import { EditorContent, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import { Markdown } from "@tiptap/markdown";
import {
  Bold,
  Italic,
  List,
  ListOrdered,
  Quote,
  Code,
  Link,
  Undo2,
  Redo2,
  Minus,
  Download,
} from "lucide-react";
import { fileName, requiresSource, type Note } from "./model";

export function downloadText(
  name: string,
  content: string,
  type = "text/markdown;charset=utf-8",
) {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export default function NoteEditor({
  note,
  onChange,
  disabled,
}: {
  note: Note;
  onChange: (content: string) => void;
  disabled: boolean;
}) {
  const sourceRequired = requiresSource(note.content);
  const [source, setSource] = useState(sourceRequired);
  useEffect(() => {
    if (sourceRequired) setSource(true);
  }, [sourceRequired]);
  const [linkOpen, setLinkOpen] = useState(false);
  const [url, setUrl] = useState("");
  const editor = useEditor({
    extensions: [
      StarterKit.configure({
        link: { openOnClick: false, protocols: ["https", "http", "mailto"] },
      }),
      Markdown,
    ],
    content: sourceRequired ? "" : note.content,
    contentType: "markdown",
    editable: !disabled,
    editorProps: {
      attributes: {
        "aria-label": "Note content",
        role: "textbox",
        "aria-multiline": "true",
        spellcheck: "true",
      },
    },
    onUpdate: ({ editor }) => onChange(editor.getMarkdown()),
  });
  useEffect(() => {
    editor?.setEditable(!disabled, false);
  }, [editor, disabled]);
  const showSource = source || sourceRequired;
  function switchMode(next: boolean) {
    if (!next && !sourceRequired)
      editor?.commands.setContent(note.content, {
        contentType: "markdown",
        emitUpdate: false,
      });
    setSource(next);
  }
  const tools = [
    {
      label: "Bold",
      icon: Bold,
      run: () => editor?.chain().focus().toggleBold().run(),
    },
    {
      label: "Italic",
      icon: Italic,
      run: () => editor?.chain().focus().toggleItalic().run(),
    },
    {
      label: "Bullet list",
      icon: List,
      run: () => editor?.chain().focus().toggleBulletList().run(),
    },
    {
      label: "Numbered list",
      icon: ListOrdered,
      run: () => editor?.chain().focus().toggleOrderedList().run(),
    },
    {
      label: "Quote",
      icon: Quote,
      run: () => editor?.chain().focus().toggleBlockquote().run(),
    },
    {
      label: "Code block",
      icon: Code,
      run: () => editor?.chain().focus().toggleCodeBlock().run(),
    },
    {
      label: "Divider",
      icon: Minus,
      run: () => editor?.chain().focus().setHorizontalRule().run(),
    },
    {
      label: "Undo",
      icon: Undo2,
      run: () => editor?.chain().focus().undo().run(),
    },
    {
      label: "Redo",
      icon: Redo2,
      run: () => editor?.chain().focus().redo().run(),
    },
  ];
  return (
    <section className="editor-pane" aria-label="Markdown editor">
      <div className="editor-heading">
        <span className="muted">{note.path}</span>
        <div className="editor-actions">
          <div className="segmented">
            <button
              aria-pressed={!showSource}
              disabled={sourceRequired || disabled}
              onClick={() => switchMode(false)}
            >
              Write
            </button>
            <button
              aria-pressed={showSource}
              disabled={disabled}
              onClick={() => switchMode(true)}
            >
              Source
            </button>
          </div>
          <button
            className="icon-button"
            title="Download Markdown"
            aria-label="Download Markdown"
            onClick={() => downloadText(fileName(note.path), note.content)}
          >
            <Download size={17} />
          </button>
        </div>
      </div>
      {!showSource && (
        <div className="formatting" role="toolbar" aria-label="Formatting">
          <select
            aria-label="Text style"
            disabled={disabled}
            defaultValue="paragraph"
            onChange={(event) => {
              const level = Number(event.target.value);
              if (level)
                editor
                  ?.chain()
                  .focus()
                  .toggleHeading({ level: level as 1 | 2 | 3 })
                  .run();
              else editor?.chain().focus().setParagraph().run();
            }}
          >
            <option value="paragraph">Paragraph</option>
            <option value="1">Heading 1</option>
            <option value="2">Heading 2</option>
            <option value="3">Heading 3</option>
          </select>
          {tools.map(({ label, icon: Icon, run }) => (
            <button
              key={label}
              aria-label={label}
              title={label}
              disabled={disabled}
              onClick={run}
            >
              <Icon size={17} />
            </button>
          ))}
          <button
            aria-label="Insert link"
            title="Insert link"
            disabled={disabled}
            onClick={() => {
              setUrl(editor?.getAttributes("link").href ?? "");
              setLinkOpen(!linkOpen);
            }}
          >
            <Link size={17} />
          </button>
        </div>
      )}
      {linkOpen && !showSource && (
        <form
          className="link-form"
          onSubmit={(event) => {
            event.preventDefault();
            if (/^(https?:\/\/|mailto:)/i.test(url)) {
              editor
                ?.chain()
                .focus()
                .extendMarkRange("link")
                .setLink({ href: url })
                .run();
              setLinkOpen(false);
            }
          }}
        >
          <input
            aria-label="Link URL"
            type="url"
            required
            placeholder="https://example.com"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
          />
          <button className="primary">Apply link</button>
          <button
            type="button"
            onClick={() => {
              editor?.chain().focus().unsetLink().run();
              setLinkOpen(false);
            }}
          >
            Remove link
          </button>
        </form>
      )}
      {sourceRequired && (
        <p className="source-notice">
          This note uses advanced Markdown. Source editing preserves its front
          matter, HTML, images, tables, or task lists.
        </p>
      )}
      <div className="document-scroll">
        {showSource ? (
          <textarea
            className="source-editor"
            aria-label="Markdown source"
            spellCheck={false}
            value={note.content}
            disabled={disabled}
            onChange={(e) => onChange(e.target.value)}
          />
        ) : (
          <EditorContent editor={editor} />
        )}
      </div>
      <footer className="editor-footer">
        <span>
          {note.content.trim() ? note.content.trim().split(/\s+/).length : 0}{" "}
          words <span className="separator">·</span> Markdown
        </span>
        <span>
          {note.base === note.content
            ? "No uncommitted changes"
            : "Uncommitted changes"}
        </span>
      </footer>
    </section>
  );
}
