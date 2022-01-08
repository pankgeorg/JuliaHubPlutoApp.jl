function environment(client, html, useEffect, useState, useMemo) {
  const useJuliaHubInfo = (notebook_id) => {
    const [username, setUsername] = useState(null);
    const [savingFolder, setSavingFolder] = useState(null);
    const [savingName, setSavingName] = useState(null);
    const [filename, setFileNameFast] = useState();
    const [currentNotebookFolder, setCurrentNotebookFolder] =
      useState("Default");
    const [folders, setFolders] = useState([]);

    useEffect(() => {
      client.send("juliahub_initiate").then((response) => {
        const nb = response.message.folders
          .flatMap(({ name, notebooks }) =>
            notebooks.map((n) => ({ ...n, folder_name: name }))
          )
          .find(({ notebook_id: nbid }) => nbid === notebook_id);
        setUsername(response.message.username);
        setFolders(response.message.folders);

        setFileNameFast(nb?.name);
        setCurrentNotebookFolder(nb?.folder_name);
      });
    }, [client, setUsername, setFolders]);

    const onchangefolder = useMemo(
      () => (e) => {
        const selected = e.target.value;
        if (!notebook_id || !selected) return;
        const patch_data = { id: notebook_id, folder: selected };
        setSavingFolder("Saving");
        client
          .send("juliahub_notebook_patch", patch_data)
          .then(({ message }) => {
            if (message.success) {
              setSavingFolder("Success");
              setTimeout(() => setSavingFolder(null), 10000);
              setCurrentNotebookFolder(selected);
              return message;
            }
            alert(
              "Failed to change folder! 😢 Please try again or contact the JuliaHub Support"
            );
            return message;
          });
      },
      [notebook_id, setSavingFolder, setCurrentNotebookFolder, client]
    );
    const onsave = useMemo(
      () =>
        _.throttle((new_name) => {
          if (!notebook_id || !new_name) return;
          const patch_data = { id: notebook_id, notebook: new_name };
          setSavingName("Saving");
          client
            .send("juliahub_notebook_patch", patch_data)
            .then(({ message }) => {
              if (message.success) {
                setSavingName("Success");
                setFileNameFast(new_name);
                setTimeout(() => setSavingName(null), 10000);
                return message;
              }
              alert(
                "Failed to change notebook name! 😢 Please try again or contact the JuliaHub Support"
              );
              return message;
            });
        }, 250),
      [notebook_id, setSavingName, setFileNameFast, client]
    );
    return {
      onsave,
      onchangefolder,
      savingStatus: { savingFolder, savingName },
      username,
      currentNotebookFolder,
      folders,
      filename,
      setFileNameFast,
    };
  };

  const custom_editor_header_component = ({ notebook_id }) => {
    const {
      onsave,
      onchangefolder,
      filename,
      savingStatus: { savingFolder, savingName },
      username,
      setFileNameFast,
      currentNotebookFolder,
      folders,
    } = useJuliaHubInfo(notebook_id);

    useEffect(() => {
      setTimeout(
        () =>
          filename
            ? (document.title = `🎈 ${filename} - a Pluto.jl Notebook on JuliaHub!`)
            : (document.title = ` 🎈 Pluto.jl Notebook 🎈 on JuliaHub!`),
        200
      );
    }, [filename]);

    return html`<div id="folder-dropdown-container">
      <style>
        #folder-dropdown-container {
          width: 14rem;
          margin: 0.5rem 1rem;
          padding: 0 1rem;
          display: flex;
          flex-flow: row nowrap;
        }

        #folder-dropdown-container > * {
          margin-left: 0.5rem;
          border-radius: 0.25rem;
          min-width: 10rem;
        }
      </style>
      <select id="folder-dropdown" onchange=${onchangefolder}>
        <option value="Default" selected=${currentNotebookFolder === "Default"}>Default</option>
        ${folders
          .filter(({ name }) => name !== "Default")
          .map(
            ({ name }) =>
              html`<option
                key=${name}
                selected=${name === currentNotebookFolder}
                value=${name}
              >
                ${name}
              </option>`
          )}
      </select>
      <span style="min-width: 2rem"
        >${savingFolder === "Saving" && "..."}
        ${savingFolder === "Success" && "✅"}</span
      >
      <input
        value=${filename}
        onchange=${(e) => setFileNameFast(e.target.value)}
      />
      <span style="min-width: 2rem"
        >${savingName == null &&
        html`<button onclick=${() => onsave(filename)}>Rename</button>`}
        ${savingName === "Saving new name" && "..."}
        ${savingName === "Success" && "✅"}</span
      >
    </div>`;
  };

  const custom_welcome = () => {
    return "Welcome!";
  };
  const custom_recent = ({ combined, recents, client, setState, cl }) => {
    const { folders } = useJuliaHubInfo();
    const running = new Set(
      combined
        ?.filter(({ notebook_id }) => notebook_id != null)
        .map(({ notebook_id }) => notebook_id) ?? []
    );
    const transitioning = new Set(
      combined
        ?.filter?.(({ transitioning }) => transitioning)
        ?.map?.(({ notebook_id }) => notebook_id) ?? []
    );

    const start_stop = useMemo(
      () =>
        ({ notebook_id, running, transitioning }) => {
          if (transitioning) {
            return;
          }

          if (running) {
            if (confirm("Shut down notebook process?")) {
              client.send(
                "shutdown_notebook",
                {
                  keep_in_session: false,
                },
                {
                  notebook_id,
                },
                false
              );
            }
          } else {
            window.location.replace(`/open?jhnb=${notebook_id}`);
          }
        },
      []
    );

    return html`<h4>JuliaHub Notebooks:</h4>
      <ul id="recent">
        ${folders.map(
          ({ name, visibility, notebooks }) => html` <li>
              <h5>${name} (${visibility})</h5>
            </li>
            ${notebooks.map(
              ({ name, notebook_id }) => html`<li
                key=${notebook_id}
                class=${cl({
                  running: running.has(notebook_id),
                  recent: !running.has(notebook_id),
                  transitioning: transitioning.has(notebook_id),
                })}
              >
                <button
                  onclick=${() =>
                    start_stop({
                      notebook_id,
                      transitioning: transitioning.has(notebook_id),
                      running: running.has(notebook_id),
                    })}
                  title=${running.has(notebook_id)
                    ? "Shut down notebook"
                    : "Start notebook in background"}
                >
                  <span></span>
                </button>
                <a href=${`/open?jhnb=${notebook_id}`}>${name}</a>
              </li>`
            )}`
        )}
      </ul>`;
  };
  const custom_filepicker = {
    text: "Open from URL",
    placeholder: "Paste a URL",
  };
  return {
    custom_editor_header_component,
    custom_welcome,
    custom_recent,
    custom_filepicker,
    show_samples: false,
  };
}

export default environment;
