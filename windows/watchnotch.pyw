import os
from pathlib import Path
import tkinter as tk
from tkinter import messagebox

from panel import Panel


def main():
    import msvcrt
    root = tk.Tk()
    root.withdraw()
    folder = Path(os.environ["LOCALAPPDATA"]) / "watchnotch"
    try:
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / "app.lock").open("a+b") as lock:
            lock.seek(0)
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                messagebox.showinfo("watchnotch", "watchnotch is already open.", parent=root)
                return
            Panel(root, folder / "library.json")
            root.deiconify()
            root.mainloop()
    except (OSError, ValueError, KeyError, TypeError) as error:
        messagebox.showerror("watchnotch", f"Could not open the session library.\n{error}", parent=root)


if __name__ == "__main__":
    main()
