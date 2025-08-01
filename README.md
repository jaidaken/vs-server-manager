# VintageStory Server Manager

A real-time terminal interface for managing VintageStory game servers.

## Dependencies

**System Commands:**
- `pgrep`, `ps` (procps package)
- `screen` (screen package)
- `dotnet` (.NET Runtime)
- `bash` (bash package)


## Usage

```bash
chmod +x server.sh
./server.sh
```

## Commands

**Manager Commands:**
- `start` / `s` - Start server
- `stop` / `st` - Stop server
- `restart` / `r` - Restart server
- `players` / `p` - Show online players
- `loginfo` / `li` - Log information
- `help` / `h` - Show help
- `quit` / `exit` / `q` - Exit

**Server Commands:**
- `/command` - Send server command to VintageStory server

**Navigation:**
- Arrow keys/mouse wheel (if terminal supports) - Scroll log
- Page Up/Down - Page scroll
- Home/End - Jump to start/end

## Configuration

**Change Data Directory:**
Edit these lines in `server.sh`:
```python
self.vs_path = '/home/vintagestory/server'      # Server files location
self.data_path = '/home/vintagestory/server/files'  # Game data location
```

**Default Paths:**
- Server: `/home/vintagestory/server`
- Data: `/var/vintagestory/data`
- Screen session: `vintagestory_server`
