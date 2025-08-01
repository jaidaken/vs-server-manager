#!/usr/bin/env python3
import os
import sys
import time
import signal
import subprocess
import threading
import json
import select
import termios
import tty
import fcntl
import struct
from pathlib import Path
from typing import Optional, List, Dict, Any, Tuple
from collections import deque
import re

class TerminalColors:
    """ANSI color codes for terminal output"""
    # Reset
    RESET = "\033[0m"

    # Colors
    BLACK = "\033[30m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN = "\033[36m"
    WHITE = "\033[37m"

    # Bright colors
    BRIGHT_BLACK = "\033[90m"
    BRIGHT_RED = "\033[91m"
    BRIGHT_GREEN = "\033[92m"
    BRIGHT_YELLOW = "\033[93m"
    BRIGHT_BLUE = "\033[94m"
    BRIGHT_MAGENTA = "\033[95m"
    BRIGHT_CYAN = "\033[96m"
    BRIGHT_WHITE = "\033[97m"

    # Background colors
    BG_BLACK = "\033[40m"
    BG_RED = "\033[41m"
    BG_GREEN = "\033[42m"
    BG_YELLOW = "\033[43m"
    BG_BLUE = "\033[44m"
    BG_MAGENTA = "\033[45m"
    BG_CYAN = "\033[46m"
    BG_WHITE = "\033[47m"

    # Bright background colors
    BG_BRIGHT_BLACK = "\033[100m"
    BG_BRIGHT_RED = "\033[101m"
    BG_BRIGHT_GREEN = "\033[102m"
    BG_BRIGHT_YELLOW = "\033[103m"
    BG_BRIGHT_BLUE = "\033[104m"
    BG_BRIGHT_MAGENTA = "\033[105m"
    BG_BRIGHT_CYAN = "\033[106m"
    BG_BRIGHT_WHITE = "\033[107m"

class TerminalControl:
    """Terminal control functions using ANSI escape codes"""

    @staticmethod
    def clear_screen():
        """Clear entire screen"""
        return "\033[2J"

    @staticmethod
    def clear_line():
        """Clear current line"""
        return "\033[2K"

    @staticmethod
    def move_cursor(row: int, col: int):
        """Move cursor to position"""
        return f"\033[{row};{col}H"

    @staticmethod
    def save_cursor():
        """Save cursor position"""
        return "\033[s"

    @staticmethod
    def restore_cursor():
        """Restore cursor position"""
        return "\033[u"

    @staticmethod
    def hide_cursor():
        """Hide cursor"""
        return "\033[?25l"

    @staticmethod
    def show_cursor():
        """Show cursor"""
        return "\033[?25h"

    @staticmethod
    def alternate_screen():
        """Switch to alternate screen"""
        return "\033[?1049h"

    @staticmethod
    def main_screen():
        """Switch back to main screen"""
        return "\033[?1049l"

class VintageStoryServerManager:
    def __init__(self):
        # Configuration
        self.username = 'vintagestory'
        self.vs_path = '/home/vintagestory/server'
        self.data_path = '/var/vintagestory/data'
        self.screen_name = 'vintagestory_server'
        self.service = "VintagestoryServer.dll"
        self.pid_file = '/tmp/vintagestory_server.pid'
        self.log_file = f"{self.data_path}/Logs/server-main.log"
        # Debug: Log file path (commented out to prevent drawing interference)
        # print(f"Log file path: {self.log_file}", file=sys.stderr)

        # UI state
        self.terminal_fd = sys.stdin.fileno()
        self.old_terminal_settings = None
        self.max_y, self.max_x = 0, 0
        self.log_lines = deque()  # Unlimited log buffer - no maxlen restriction
        self.command_buffer = ""
        self.command_buffer_max = 1024  # Limit command buffer size
        self.status = "OFF"
        self.last_log_size = 0
        self.running = True
        self.cursor_visible = True
        self.scroll_offset = 0  # For log scrolling

        # CPU monitoring state
        self.last_cpu_update = 0
        self.cached_cpu_percent = "N/A"
        self.cpu_update_interval = 1.0  # Update CPU every second

        # Memory monitoring state
        self.last_mem_update = 0
        self.cached_mem_percent = "N/A"
        self.mem_update_interval = 1.0  # Update memory every second

        # PID monitoring state
        self.cached_pid = None
        self.pid_update_needed = True  # Initialize PID on startup

        # Command log system
        self.command_log = deque(maxlen=50)  # Keep last 50 command events
        self.command_log.append("Manager started - Ready for commands")

        # Player tracking system
        self.connected_players = set()  # Set of currently connected players
        self.player_count = 0
        self.last_player_update = 0
        self.player_update_interval = 60.0  # Update player count every 60 seconds
        self.player_update_thread = None
        self.player_update_running = True

        # Log color tracking for indented lines
        self.last_log_color = TerminalColors.WHITE  # Track color of previous log line

        # Threading for log monitoring
        self.log_thread = None
        self.log_thread_running = True
        self.log_lock = threading.Lock()





        # Input handling state
        self.escape_buffer = ""  # Buffer for incomplete escape sequences

        # Mouse support detection
        self.mouse_supported = False
        self.mouse_enabled = False

    def get_terminal_size(self) -> Tuple[int, int]:
        """Get terminal dimensions"""
        try:
            hw = struct.unpack('hh', fcntl.ioctl(self.terminal_fd, termios.TIOCGWINSZ, '1234'))
            return hw[0], hw[1]  # rows, cols
        except:
            return 24, 80  # fallback

    def check_terminal_resize(self):
        """Check if terminal size has changed and reset drawn flags if needed"""
        new_size = self.get_terminal_size()
        if new_size != (self.max_y, self.max_x):
            self.max_y, self.max_x = new_size
            # Reset drawn flags to force redraw
            if hasattr(self, '_borders_drawn'):
                delattr(self, '_borders_drawn')
            if hasattr(self, '_help_drawn'):
                delattr(self, '_help_drawn')

            if hasattr(self, '_last_log_hash'):
                delattr(self, '_last_log_hash')
            if hasattr(self, '_last_command_buffer'):
                delattr(self, '_last_command_buffer')
            if hasattr(self, '_last_feedback_hash'):
                delattr(self, '_last_feedback_hash')

            # Mark that terminal was resized
            self._terminal_resized = True

    def setup_terminal(self):
        """Setup terminal for raw input"""
        try:
            self.old_terminal_settings = termios.tcgetattr(self.terminal_fd)
            tty.setraw(self.terminal_fd)
        except Exception as e:
            print(f"Terminal setup error: {e}", file=sys.stderr)
            # Continue without raw mode if it fails

        # Get terminal size
        self.max_y, self.max_x = self.get_terminal_size()

        # Switch to alternate screen and hide cursor
        sys.stdout.write(TerminalControl.alternate_screen())
        sys.stdout.write(TerminalControl.hide_cursor())
        sys.stdout.write(TerminalControl.clear_screen())

        # Disable mouse tracking completely for SSH stability
        # Mouse events are causing crashes in SSH environments
        self.mouse_enabled = False

        sys.stdout.flush()

    def restore_terminal(self):
        """Restore terminal to original state"""
        if self.old_terminal_settings:
            termios.tcsetattr(self.terminal_fd, termios.TCSADRAIN, self.old_terminal_settings)

        # Mouse tracking disabled for SSH stability
        pass

        # Switch back to main screen and show cursor
        sys.stdout.write(TerminalControl.main_screen())
        sys.stdout.write(TerminalControl.show_cursor())
        sys.stdout.flush()

    def check_dependencies(self):
        """Check if required commands and packages are available"""
        print("🔍 Checking dependencies...")

        # Check system commands
        required_commands = {
            'pgrep': 'procps',
            'screen': 'screen',
            'dotnet': '.NET Runtime',
            'bash': 'bash',
            'ps': 'procps'
        }
        missing_commands = []

        for cmd, package in required_commands.items():
            try:
                result = subprocess.run(['which', cmd], capture_output=True)
                if result.returncode != 0:
                    missing_commands.append((cmd, package))
            except subprocess.CalledProcessError:
                missing_commands.append((cmd, package))

        # Check Python modules
        missing_builtin = []
        builtin_modules = [
            'os', 'sys', 'time', 'signal', 'subprocess', 'threading',
            'json', 'select', 'termios', 'tty', 'fcntl', 'struct',
            'pathlib', 'typing', 'collections', 're'
        ]

        for module in builtin_modules:
            try:
                __import__(module)
            except ImportError:
                missing_builtin.append(module)

        # Check terminal capabilities
        terminal_issues = []
        if not sys.stdout.isatty():
            terminal_issues.append("Not running in a terminal")

        term = os.environ.get('TERM', '')
        if not term or term == 'dumb':
            terminal_issues.append("Unsupported terminal type (set TERM=xterm-256color)")

        # Display results
        if missing_commands or missing_builtin or terminal_issues:
            print("\n❌ DEPENDENCY CHECK FAILED")
            print("=" * 50)

            if missing_commands:
                print("\n🔧 Missing System Commands:")
                for cmd, package in missing_commands:
                    print(f"   ❌ {cmd} ({package})")

                print("\n📦 Installation Commands:")
                print("   Ubuntu/Debian:")
                print("     sudo apt update")
                print("     sudo apt install procps screen bash python3")
                print("\n   CentOS/RHEL/Fedora:")
                print("     sudo yum install procps screen bash python3")
                print("     # or: sudo dnf install procps screen bash python3")
                print("\n   .NET Runtime:")
                print("     https://dotnet.microsoft.com/en-us/download")

            if missing_builtin:
                print(f"\n🐍 Missing Python Modules: {', '.join(missing_builtin)}")
                print("   This indicates a Python installation issue.")
                print("   Try: sudo apt install python3")

            if terminal_issues:
                print(f"\n💻 Terminal Issues: {', '.join(terminal_issues)}")
                print("   Make sure you're running in a proper terminal with:")
                print("   export TERM=xterm-256color")

            print("\n" + "=" * 50)
            print("Press Enter to continue anyway, or Ctrl+C to exit and install dependencies...")

            try:
                input()
            except KeyboardInterrupt:
                print("\n❌ Exiting. Please install dependencies and try again.")
                sys.exit(1)
        else:
            print("✅ All dependencies satisfied!")

    def get_process_info(self) -> Dict[str, Any]:
        """Get current process information"""
        # Check running processes - look for actual dotnet process
        running_pids = []

        try:
            # First, get all dotnet processes
            result = subprocess.run(
                ['pgrep', '-f', 'dotnet.*VintagestoryServer.dll'],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                # Get the actual dotnet process PIDs
                dotnet_pids = [int(pid) for pid in result.stdout.strip().split('\n') if pid]

                # Filter to only dotnet processes (not screen processes)
                for pid in dotnet_pids:
                    try:
                        # Check if this PID is actually a dotnet process
                        with open(f'/proc/{pid}/comm', 'r') as f:
                            comm = f.read().strip()
                        if comm == 'dotnet':
                            running_pids.append(pid)
                    except (FileNotFoundError, PermissionError):
                        continue
        except (ValueError, subprocess.CalledProcessError):
            pass

        # Also check for screen session
        screen_running = False
        try:
            result = subprocess.run(
                ['screen', '-list', self.screen_name],
                capture_output=True, text=True
            )
            screen_running = result.returncode == 0 and self.screen_name in result.stdout
        except subprocess.CalledProcessError:
            pass

        return {
            'running_pids': running_pids,
            'screen_running': screen_running,
            'is_running': len(running_pids) > 0 or screen_running
        }

    def update_status(self):
        """Update server status"""
        process_info = self.get_process_info()
        old_status = self.status
        self.status = "ON" if process_info['is_running'] else "OFF"

        # If server just started (status changed from OFF to ON), trigger immediate player update
        if old_status == "OFF" and self.status == "ON":
            # Trigger immediate player count update
            threading.Thread(target=self.trigger_player_update, daemon=True).start()

    def trigger_player_update(self):
        """Trigger an immediate player count update"""
        if self.get_process_info()['is_running']:
            if self.send_command("list clients"):
                time.sleep(2)
                self.parse_list_clients_output()
                self.add_command_log(f"Manual player count update: {len(self.connected_players)} players")

    def get_pid(self) -> Optional[int]:
        """Get cached PID, updating only when needed"""
        if self.pid_update_needed:
            if hasattr(self, '_pid_delay_needed'):
                # Wait 2 seconds before updating PID (for manual start)
                time.sleep(2)
                delattr(self, '_pid_delay_needed')
            else:
                # Immediate update (for script startup)
                pass

            process_info = self.get_process_info()
            if process_info['running_pids']:
                self.cached_pid = process_info['running_pids'][0]
            else:
                self.cached_pid = None
            self.pid_update_needed = False

        return self.cached_pid

    def start_server(self) -> bool:
        """Start the VintageStory server (like old UI)"""
        if self.get_process_info()['is_running']:
            return True

        # Check if service file exists
        service_path = os.path.join(self.vs_path, self.service)
        if not os.path.exists(service_path):
            return False

        # Create data path if it doesn't exist
        os.makedirs(self.data_path, exist_ok=True)

        # Start server (simpler like old UI)
        invocation = f"dotnet {self.service} --dataPath \"{self.data_path}\""
        screen_cmd = f"screen -h 1024 -dmS {self.screen_name} {invocation}"

        try:
            subprocess.run(['bash', '-c', screen_cmd], check=True)
            # Mark PID for update after 2 seconds (manual start)
            self.pid_update_needed = True
            self._pid_delay_needed = True

            # Force log refresh after server start to catch initial lines
            threading.Thread(target=self.force_log_refresh, daemon=True).start()

            # Non-blocking: return immediately, status will be updated in main loop
            return True
        except subprocess.CalledProcessError:
            pass

        return False

    def stop_server(self) -> bool:
        """Stop the VintageStory server gracefully (like old UI)"""
        process_info = self.get_process_info()
        if not process_info['is_running']:
            return True

        try:
            # Simply send the stop command to the server (like old UI)
            return self.send_command("stop")
        except Exception:
            return False

    def send_command(self, command: str) -> bool:
        """Send a command to the server (like old UI)"""
        if not self.get_process_info()['is_running']:
            return False

        try:
            screen_cmd = f"screen -p 0 -S {self.screen_name} -X eval 'stuff \"/{command}\"\\015'"
            subprocess.run(['bash', '-c', screen_cmd], check=True)
            return True
        except subprocess.CalledProcessError:
            return False

    def add_command_log(self, message: str):
        """Add a message to the command log"""
        timestamp = time.strftime("%H:%M:%S")
        self.command_log.append(f"[{timestamp}] {message}")

    def force_log_refresh(self):
        """Force a complete log refresh to catch any missed lines"""
        time.sleep(1)  # Wait a moment for server to start writing logs
        try:
            if os.path.exists(self.log_file):
                with open(self.log_file, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    if content:
                        lines = content.splitlines()
                        with self.log_lock:
                            self.log_lines.clear()
                            self.log_lines.extend(lines)
                        self.last_log_size = os.path.getsize(self.log_file)
        except Exception as e:
            print(f"Force log refresh error: {e}", file=sys.stderr)

    def restart_sequence(self):
        """Background thread for restart sequence"""
        # Send stop command
        self.stop_server()

        # Wait 10 seconds for server to stop
        time.sleep(20)

        # Start new server
        if self.start_server():
            self.update_status()
            self.add_command_log("Server restarted successfully!")
        else:
            self.add_command_log("Failed to restart server!")



    def log_monitor_thread(self):
        """Background thread that continuously monitors the log file"""
        # Read existing log content on startup
        if os.path.exists(self.log_file):
            try:
                with open(self.log_file, 'r', encoding='utf-8', errors='ignore') as f:
                    existing_content = f.read()
                    self.last_log_size = os.path.getsize(self.log_file)

                    if existing_content:
                        existing_lines = existing_content.splitlines()
                        with self.log_lock:
                            self.log_lines.extend(existing_lines)
                            # Debug: Startup log loading (commented out to prevent drawing interference)
                            # print(f"Loaded {len(existing_lines)} existing log lines on startup", file=sys.stderr)

                        # Parse existing log for player connections/disconnections
                        # self.parse_existing_log_for_players(existing_lines)  # Disabled - using timer-based updates
            except Exception as e:
                print(f"Error reading existing log: {e}", file=sys.stderr)

        while self.log_thread_running:
            try:
                if os.path.exists(self.log_file):
                    current_size = os.path.getsize(self.log_file)

                    if current_size > self.last_log_size:
                        # Use a more robust file reading approach
                        try:
                            with open(self.log_file, 'r', encoding='utf-8', errors='ignore') as f:
                                f.seek(self.last_log_size)
                                new_content = f.read()

                                if new_content:
                                    new_lines = new_content.splitlines()
                                    with self.log_lock:
                                        self.log_lines.extend(new_lines)
                                        # Debug: New log lines tracking (commented out to prevent drawing interference)
                                        # print(f"Added {len(new_lines)} new log lines", file=sys.stderr)

                                    # Parse new lines for player events
                                    # self.parse_new_log_lines_for_players(new_lines) # Disabled - using timer-based updates

                                # Update size after successful read
                                self.last_log_size = current_size

                        except (IOError, OSError) as e:
                            # If file read fails, try to recover by reading from beginning
                            try:
                                with open(self.log_file, 'r', encoding='utf-8', errors='ignore') as f:
                                    new_content = f.read()
                                    if new_content:
                                        new_lines = new_content.splitlines()
                                        with self.log_lock:
                                            self.log_lines.clear()
                                            self.log_lines.extend(new_lines)
                                        self.last_log_size = current_size
                            except:
                                pass

                    elif current_size < self.last_log_size:
                        # Log file was truncated or rotated
                        try:
                            with open(self.log_file, 'r', encoding='utf-8', errors='ignore') as f:
                                new_content = f.read()
                                if new_content:
                                    new_lines = new_content.splitlines()
                                    with self.log_lock:
                                        self.log_lines.clear()
                                        self.log_lines.extend(new_lines)
                                    self.last_log_size = current_size
                        except:
                            pass

                # Shorter sleep for more responsive updates
                time.sleep(0.005)  # 5ms for faster updates

            except (IOError, OSError) as e:
                # Shorter sleep on error
                time.sleep(0.005)
                pass
            except Exception as e:
                # Shorter sleep on exception
                time.sleep(0.005)
                pass

    def start_log_monitor(self):
        """Start the background log monitoring thread"""
        self.log_thread = threading.Thread(target=self.log_monitor_thread, daemon=True)
        self.log_thread.start()

        # Start player update thread
        self.start_player_update_thread()

    def stop_log_monitor(self):
        """Stop the background log monitoring thread"""
        self.log_thread_running = False
        if self.log_thread and self.log_thread.is_alive():
            self.log_thread.join(timeout=1.0)

        # Stop player update thread
        self.stop_player_update_thread()

    def get_cpu_percentage(self) -> str:
        """Get CPU percentage for the dotnet process, with caching"""
        current_time = time.time()

                # Check if we need to update (every second)
        if current_time - self.last_cpu_update >= self.cpu_update_interval:
            cached_pid = self.get_pid()

            if cached_pid is not None:
                try:
                    result = subprocess.run(
                        ['ps', '-p', str(cached_pid), '-o', '%cpu'],
                        capture_output=True, text=True
                    )
                    if result.returncode == 0:
                        lines = result.stdout.strip().split('\n')
                        if len(lines) >= 2:
                            self.cached_cpu_percent = lines[1].strip()
                        else:
                            self.cached_cpu_percent = "N/A"
                    else:
                        self.cached_cpu_percent = "N/A"
                except (subprocess.CalledProcessError, ValueError):
                    self.cached_cpu_percent = "N/A"
            else:
                self.cached_cpu_percent = "N/A"

            self.last_cpu_update = current_time

        return self.cached_cpu_percent

    def get_memory_percentage(self) -> str:
        """Get memory percentage for the dotnet process, with caching"""
        current_time = time.time()

        # Check if we need to update (every second)
        if current_time - self.last_mem_update >= self.mem_update_interval:
            cached_pid = self.get_pid()

            if cached_pid is not None:
                try:
                    result = subprocess.run(
                        ['ps', '-p', str(cached_pid), '-o', '%mem'],
                        capture_output=True, text=True
                    )
                    if result.returncode == 0:
                        lines = result.stdout.strip().split('\n')
                        if len(lines) >= 2:
                            self.cached_mem_percent = lines[1].strip()
                        else:
                            self.cached_mem_percent = "N/A"
                    else:
                        self.cached_mem_percent = "N/A"
                except (subprocess.CalledProcessError, ValueError):
                    self.cached_mem_percent = "N/A"
            else:
                self.cached_mem_percent = "N/A"

            self.last_mem_update = current_time

        return self.cached_mem_percent

    def get_player_count(self) -> str:
        """Get current player count, with caching"""
        current_time = time.time()

        # Check if we need to update (every 60 seconds)
        if current_time - self.last_player_update >= self.player_update_interval:
            # Update player count from connected players set
            self.player_count = len(self.connected_players)
            self.last_player_update = current_time

        return str(self.player_count)

    def player_update_thread(self):
        """Background thread that updates player count every minute"""
        while self.player_update_running:
            try:
                if self.get_process_info()['is_running']:
                    # Send /list clients command to get current players
                    if self.send_command("list clients"):
                        # Wait a moment for the command to be processed
                        time.sleep(2)
                        # Parse the log for the /list clients output
                        self.parse_list_clients_output()
                        # Debug: Log the update (commented out to prevent spam)
                        # self.add_command_log(f"Player count updated: {len(self.connected_players)} players")
                else:
                    # Server not running, clear player list
                    self.connected_players.clear()
                    self.player_count = 0

                # Sleep for the update interval
                time.sleep(self.player_update_interval)

            except Exception as e:
                # Log error and continue with shorter sleep
                print(f"Player update error: {e}", file=sys.stderr)
                time.sleep(10)  # Shorter sleep on error

    def start_player_update_thread(self):
        """Start the background player update thread"""
        self.player_update_thread = threading.Thread(target=self.player_update_thread, daemon=True)
        self.player_update_thread.start()

        # Do an initial player count check after a short delay
        threading.Thread(target=self.initial_player_check, daemon=True).start()

    def initial_player_check(self):
        """Initial player count check when script starts"""
        # Check if server is running and do initial player count immediately
        if self.get_process_info()['is_running']:
            self.add_command_log("Performing initial player count check...")
            # Use the same trigger method for consistency
            self.trigger_player_update()
        else:
            self.add_command_log("Server not running - no initial player check needed")

    def stop_player_update_thread(self):
        """Stop the background player update thread"""
        self.player_update_running = False
        if self.player_update_thread and self.player_update_thread.is_alive():
            self.player_update_thread.join(timeout=1.0)

    def parse_list_clients_output(self):
        """Parse the log for /list clients output"""
        try:
            if os.path.exists(self.log_file):
                with open(self.log_file, 'r', encoding='utf-8', errors='ignore') as f:
                    # Read the last 100 lines to find recent /list clients output (increased from 50)
                    lines = f.readlines()
                    recent_lines = lines[-100:] if len(lines) > 100 else lines

                    # Clear current players
                    self.connected_players.clear()

                    # Look for /list clients output
                    for line in recent_lines:
                        line = line.strip()

                        # Handle /list clients output format: "[2] Jaidaken [::ffff:192.168.1.239]:55786"
                        if line.startswith("[") and "] " in line and "[" in line[line.find("] ")+2:]:
                            try:
                                # Extract player name between "] " and " ["
                                parts = line.split("] ")
                                if len(parts) >= 2:
                                    player_part = parts[1]
                                    if " [" in player_part:
                                        player_name = player_part.split(" [")[0].strip()
                                        if player_name and player_name not in self.connected_players:
                                            self.connected_players.add(player_name)
                            except Exception:
                                pass  # Skip malformed lines

                    # Update player count
                    self.player_count = len(self.connected_players)

        except Exception as e:
            # Log error for debugging
            print(f"Parse list clients error: {e}", file=sys.stderr)

    def get_online_players_list(self) -> List[str]:
        """Get list of currently online players"""
        return list(self.connected_players)

    def draw_header(self):
        """Draw the header with title and status"""
        # Always update - metrics change frequently
        current_status = self.status

        title = " VINTAGESTORY SERVER MANAGER "

        # Get PID information (cached, updates only when server starts)
        cached_pid = self.get_pid()

        # Create user-friendly status text
        if self.status == "ON":
            status_text = "● RUNNING"
        else:
            status_text = "● STOPPED"

        if cached_pid is not None:
            pid_text = f" 🖥️ PID: {cached_pid}"

            # Get CPU percentage (cached, updates every second)
            cpu_percent = self.get_cpu_percentage()
            cpu_text = f" 📊 CPU: {cpu_percent}%"

            # Get memory percentage (cached, updates every second)
            mem_percent = self.get_memory_percentage()
            mem_text = f" 💾 MEM: {mem_percent}%"
        else:
            pid_text = " 🖥️ PID: N/A"
            cpu_text = " 📊 CPU: N/A"
            mem_text = " 💾 MEM: N/A"

        # Calculate positions (removed player count from header)
        title_start = 2
        status_start = self.max_x - len(status_text) - len(pid_text) - len(cpu_text) - len(mem_text) - 2

        # Draw header
        header_line = " " * self.max_x
        header_line = header_line[:title_start] + title + header_line[title_start + len(title):]
        header_line = header_line[:status_start] + status_text + pid_text + cpu_text + mem_text + header_line[status_start + len(status_text) + len(pid_text) + len(cpu_text) + len(mem_text):]

        # Apply colors
        status_color = TerminalColors.BRIGHT_GREEN if self.status == "ON" else TerminalColors.BRIGHT_RED
        pid_color = TerminalColors.BRIGHT_YELLOW if cached_pid is not None else TerminalColors.BRIGHT_BLACK
        cpu_color = TerminalColors.BRIGHT_MAGENTA if cached_pid is not None else TerminalColors.BRIGHT_BLACK
        mem_color = TerminalColors.BRIGHT_CYAN if cached_pid is not None else TerminalColors.BRIGHT_BLACK

        colored_header = (
            TerminalColors.BRIGHT_CYAN + header_line[:title_start] +
            TerminalColors.BRIGHT_WHITE + header_line[title_start:title_start + len(title)] +
            TerminalColors.BRIGHT_CYAN + header_line[title_start + len(title):status_start] +
            status_color + header_line[status_start:status_start + len(status_text)] +
            pid_color + header_line[status_start + len(status_text):status_start + len(status_text) + len(pid_text)] +
            cpu_color + header_line[status_start + len(status_text) + len(pid_text):status_start + len(status_text) + len(pid_text) + len(cpu_text)] +
            mem_color + header_line[status_start + len(status_text) + len(pid_text) + len(cpu_text):status_start + len(status_text) + len(pid_text) + len(cpu_text) + len(mem_text)] +
            TerminalColors.BRIGHT_CYAN + header_line[status_start + len(status_text) + len(pid_text) + len(cpu_text) + len(mem_text):] +
            TerminalColors.RESET
        )

        sys.stdout.write(TerminalControl.move_cursor(1, 1) + colored_header)

    def draw_feedback_frame(self):
        """Draw the command log frame between log and help areas"""
        # Calculate command log area position
        log_y = self.max_y - 6  # Between log and help areas

        # Calculate player list position
        player_list_x = self.max_x - 23  # Start 23 columns from right edge

        # Check if we need to update (only if command log has changed)
        if self.command_log:
            latest_message = list(self.command_log)[-1]
        else:
            latest_message = ""

        current_message_hash = hash(latest_message)
        if hasattr(self, '_last_feedback_hash') and self._last_feedback_hash == current_message_hash:
            return  # No change, skip drawing

        self._last_feedback_hash = current_message_hash

        # Clear command log area (only up to player list)
        sys.stdout.write(TerminalControl.move_cursor(log_y + 1, 1) + TerminalControl.clear_line())

        # Show the most recent command log entry
        if self.command_log:
            latest_message = list(self.command_log)[-1]
            # Truncate if too long (account for player list)
            max_length = player_list_x - 4
            if len(latest_message) > max_length:
                latest_message = latest_message[:max_length - 3] + "..."

            message_x = max(2, (player_list_x - len(latest_message)) // 2)
            sys.stdout.write(TerminalControl.move_cursor(log_y + 1, message_x) + TerminalColors.BRIGHT_CYAN + latest_message + TerminalColors.RESET)

    def draw_borders(self):
        """Draw simple borders around each section"""
        if hasattr(self, '_borders_drawn'):
            return
        self._borders_drawn = True

        # Simple border function
        def draw_box(x, y, width, height):
            # Top and bottom
            for i in range(width):
                sys.stdout.write(TerminalControl.move_cursor(y, x + i) + TerminalColors.BRIGHT_BLUE + "-" + TerminalColors.RESET)
                sys.stdout.write(TerminalControl.move_cursor(y + height - 1, x + i) + TerminalColors.BRIGHT_BLUE + "-" + TerminalColors.RESET)
            # Left and right
            for i in range(height):
                sys.stdout.write(TerminalControl.move_cursor(y + i, x) + TerminalColors.BRIGHT_BLUE + "|" + TerminalColors.RESET)
                sys.stdout.write(TerminalControl.move_cursor(y + i, x + width - 1) + TerminalColors.BRIGHT_BLUE + "|" + TerminalColors.RESET)
            # Corners
            sys.stdout.write(TerminalControl.move_cursor(y, x) + TerminalColors.BRIGHT_BLUE + "+" + TerminalColors.RESET)
            sys.stdout.write(TerminalControl.move_cursor(y, x + width - 1) + TerminalColors.BRIGHT_BLUE + "+" + TerminalColors.RESET)
            sys.stdout.write(TerminalControl.move_cursor(y + height - 1, x) + TerminalColors.BRIGHT_BLUE + "+" + TerminalColors.RESET)
            sys.stdout.write(TerminalControl.move_cursor(y + height - 1, x + width - 1) + TerminalColors.BRIGHT_BLUE + "+" + TerminalColors.RESET)

        # Draw main log area border
        log_width = self.max_x - 25
        log_height = self.max_y - 8
        draw_box(1, 3, log_width, log_height)

        # Draw player list border (full height including bottom)
        player_x = self.max_x - 23
        draw_box(player_x, 2, 21, self.max_y - 1)

        # Draw feedback area border
        feedback_y = self.max_y - 6
        draw_box(1, feedback_y, log_width, 2)

        # Draw help area border
        help_y = self.max_y - 4
        draw_box(1, help_y, log_width, 2)

        # Draw input area border
        input_y = self.max_y - 2
        draw_box(1, input_y, log_width, 2)

    def draw_log_area(self):
        """Draw the log display area with color coding and line wrapping"""
        log_start_y = 4
        log_end_y = self.max_y - 8  # Account for feedback frame and help lines
        log_height = log_end_y - log_start_y

        if log_height < 1:
            log_height = 1
            log_end_y = log_start_y + 1

        # Calculate log area width (leave space for player list on the right)
        log_width = self.max_x - 25  # Leave 25 columns for player list
        if log_width < 20:  # Minimum log width
            log_width = 20

        with self.log_lock:
            all_lines = list(self.log_lines)
            total_lines = len(all_lines)

            # Calculate which lines to display based on scroll offset
            if total_lines <= log_height:
                # All lines fit, no scrolling needed
                display_lines = all_lines
                self.scroll_offset = 0
            else:
                # Apply scroll offset - ensure we don't go beyond available lines
                max_offset = total_lines - log_height
                self.scroll_offset = max(0, min(self.scroll_offset, max_offset))
                start_idx = max(0, total_lines - log_height - self.scroll_offset)
                end_idx = start_idx + log_height
                display_lines = all_lines[start_idx:end_idx]

                # If we're at the end (scroll_offset = 0), ensure we show the most recent lines
                if self.scroll_offset == 0 and len(display_lines) < log_height:
                    # Adjust to show the most recent lines
                    start_idx = max(0, total_lines - log_height)
                    end_idx = total_lines
                    display_lines = all_lines[start_idx:end_idx]

        # Check if we need to update (only if lines have changed)
        current_lines_hash = hash(tuple(display_lines))
        if hasattr(self, '_last_log_hash') and self._last_log_hash == current_lines_hash:
            return  # No change, skip drawing

        self._last_log_hash = current_lines_hash

        # Clear log area (inside the border)
        for y in range(log_start_y, log_end_y):
            sys.stdout.write(TerminalControl.move_cursor(y, 2) + " " * (log_width - 2))

        # Draw log lines with syntax highlighting and line wrapping
        current_y = log_start_y
        lines_drawn = 0

        for line in display_lines:
            if current_y >= log_end_y or lines_drawn >= log_height:
                break

            # Strip timestamp from the line
            clean_line = self.strip_timestamp(line)

            # Determine color based on log type
            color = self.get_log_line_color(line)

            # Update last color for indented lines (only if not indented)
            if not line.startswith(' ') and not line.startswith('\t'):
                self.last_log_color = color

            # Wrap long lines (account for border)
            wrapped_lines = self.wrap_line(clean_line, log_width - 3)  # -3 for border spacing

            for wrapped_line in wrapped_lines:
                if current_y >= log_end_y or lines_drawn >= log_height:
                    break

                # Truncate if still too long
                display_line = wrapped_line[:log_width - 3] if len(wrapped_line) > log_width - 3 else wrapped_line

                # Draw with proper spacing from left border
                sys.stdout.write(TerminalControl.move_cursor(current_y, 2) + color + display_line + TerminalColors.RESET)
                current_y += 1
                lines_drawn += 1

    def get_log_line_color(self, line: str) -> str:
        """Get color for log line based on its type"""
        line_upper = line.upper()

        # Check for indented lines first (stack traces, etc.)
        if line.startswith(' ') or line.startswith('\t'):
            # Indented lines should inherit color from previous line
            return self.last_log_color

        if "[ERROR]" in line_upper:
            return TerminalColors.BRIGHT_RED
        elif "[WARNING]" in line_upper:
            return TerminalColors.BRIGHT_YELLOW
        elif "[EVENT]" in line_upper:
            return TerminalColors.BRIGHT_GREEN
        elif "[NOTIFICATION]" in line_upper:
            return TerminalColors.BRIGHT_CYAN
        elif "[DEBUG]" in line_upper:
            return TerminalColors.BRIGHT_BLACK
        elif "joins." in line or "left." in line:
            return TerminalColors.BRIGHT_MAGENTA  # Player events
        elif "List of online Players" in line:
            return TerminalColors.BRIGHT_WHITE  # Player list header
        elif line.strip().startswith("[") and "] " in line and "[" in line[line.find("] ")+2:]:
            return TerminalColors.BRIGHT_WHITE  # Player entries from /list clients
        else:
            return TerminalColors.WHITE  # Default color

    def wrap_line(self, line: str, max_width: int) -> List[str]:
        """Wrap a long line to fit within max_width"""
        if len(line) <= max_width:
            return [line]

        wrapped_lines = []
        current_line = ""

        # Split by words to avoid breaking words
        words = line.split()

        for word in words:
            # If adding this word would exceed the width
            if len(current_line) + len(word) + 1 > max_width:
                if current_line:
                    wrapped_lines.append(current_line)
                    current_line = word
                else:
                    # Word is longer than max_width, break it
                    wrapped_lines.append(word[:max_width])
                    current_line = word[max_width:] if len(word) > max_width else ""
            else:
                if current_line:
                    current_line += " " + word
                else:
                    current_line = word

        if current_line:
            wrapped_lines.append(current_line)

        return wrapped_lines

    def draw_player_list(self):
        """Draw the player list panel on the right side, full height (no gaps)"""
        # Calculate player list position and size - full height
        player_list_x = self.max_x - 23  # Start 23 columns from right edge
        player_list_width = 21  # 21 columns wide
        player_list_start_y = 2  # Start at the top border (row 2)
        player_list_end_y = self.max_y  # End at the bottom border (row self.max_y)

        # Draw title
        title = " 👥 PLAYERS "
        title_x = player_list_x + (player_list_width - len(title)) // 2
        sys.stdout.write(TerminalControl.move_cursor(player_list_start_y + 1, title_x) + TerminalColors.BRIGHT_WHITE + title + TerminalColors.RESET)

        # Get current players
        players = self.get_online_players_list()
        player_count = len(players)

        # Draw player count
        count_text = f" ONLINE: {player_count} "
        count_x = player_list_x + (player_list_width - len(count_text)) // 2
        count_color = TerminalColors.BRIGHT_GREEN if player_count > 0 else TerminalColors.BRIGHT_BLACK
        sys.stdout.write(TerminalControl.move_cursor(player_list_start_y + 2, count_x) + count_color + count_text + TerminalColors.RESET)

        # Clear player list area
        for y in range(player_list_start_y + 3, player_list_end_y):
            sys.stdout.write(TerminalControl.move_cursor(y, player_list_x + 1) + " " * (player_list_width - 2))

        # Draw player names
        if players:
            for i, player in enumerate(players):
                if player_list_start_y + 3 + i < player_list_end_y:  # Make sure we don't overflow
                    # Truncate long player names
                    display_name = player[:player_list_width - 6] if len(player) > player_list_width - 6 else player
                    player_text = f" 🟢 {display_name} "
                    if len(player) > player_list_width - 6:
                        player_text = player_text[:-3] + "… "

                    sys.stdout.write(TerminalControl.move_cursor(player_list_start_y + 3 + i, player_list_x + 1) + TerminalColors.BRIGHT_CYAN + player_text + TerminalColors.RESET)
        else:
            # Show "No players" message
            no_players_text = " 🔴 NO PLAYERS "
            no_players_x = player_list_x + (player_list_width - len(no_players_text)) // 2
            sys.stdout.write(TerminalControl.move_cursor(player_list_start_y + 3, no_players_x) + TerminalColors.BRIGHT_BLACK + no_players_text + TerminalColors.RESET)

    def scroll_log_up(self):
        """Scroll log up (show older lines) - faster scrolling"""
        with self.log_lock:
            total_lines = len(self.log_lines)
            log_height = self.max_y - 12  # Account for feedback frame and help lines

            if total_lines > log_height:
                # Scroll by 3 lines instead of 1 for faster navigation
                self.scroll_offset = min(self.scroll_offset + 3, total_lines - log_height)

    def scroll_log_down(self):
        """Scroll log down (show newer lines) - faster scrolling"""
        # Scroll by 3 lines instead of 1 for faster navigation
        self.scroll_offset = max(0, self.scroll_offset - 3)

    def scroll_log_page_up(self):
        """Scroll log up by one page - show more content"""
        with self.log_lock:
            total_lines = len(self.log_lines)
            log_height = self.max_y - 12  # Account for feedback frame and help lines

            if total_lines > log_height:
                # Scroll by 75% of visible area for better page navigation
                page_size = max(1, int(log_height * 0.75))
                self.scroll_offset = min(self.scroll_offset + page_size, total_lines - log_height)

    def scroll_log_page_down(self):
        """Scroll log down by one page - show more content"""
        log_height = self.max_y - 12  # Account for feedback frame and help lines
        # Scroll by 75% of visible area for better page navigation
        page_size = max(1, int(log_height * 0.75))
        self.scroll_offset = max(0, self.scroll_offset - page_size)

    def scroll_log_home(self):
        """Scroll to the beginning of the log (oldest entries)"""
        with self.log_lock:
            total_lines = len(self.log_lines)
            log_height = self.max_y - 12  # Account for feedback frame and help lines

            if total_lines > log_height:
                # Show the oldest entries (beginning of log)
                self.scroll_offset = total_lines - log_height

    def scroll_log_end(self):
        """Scroll to the end of the log (latest lines)"""
        # Show the newest entries (end of log)
        self.scroll_offset = 0

    def draw_help_area(self):
        """Draw the help/command area"""
        # Only draw help area once or when terminal size changes
        if hasattr(self, '_help_drawn') and not hasattr(self, '_terminal_resized'):
            return

        self._help_drawn = True
        if hasattr(self, '_terminal_resized'):
            delattr(self, '_terminal_resized')

        help_y = self.max_y - 3  # Adjusted for feedback frame

        # Calculate player list position
        player_list_x = self.max_x - 23  # Start 23 columns from right edge

        help_text = " ⚡ BUILT-IN: start|stop|restart|players|loginfo|help|quit "
        server_text = " 🎮 SERVER: /command [forwarded to server] "
        scroll_text = " 📜 SCROLL: ↑↓ PgUp/PgDn Home/End "

        # Clear help area (only up to player list)
        sys.stdout.write(TerminalControl.move_cursor(help_y, 1) + TerminalControl.clear_line())
        sys.stdout.write(TerminalControl.move_cursor(help_y + 1, 1) + TerminalControl.clear_line())
        sys.stdout.write(TerminalControl.move_cursor(help_y + 2, 1) + TerminalControl.clear_line())

        # Draw help text (truncate if too long)
        max_length = player_list_x - 4
        if len(help_text) > max_length:
            help_text = help_text[:max_length - 3] + "..."
        if len(server_text) > max_length:
            server_text = server_text[:max_length - 3] + "..."
        if len(scroll_text) > max_length:
            scroll_text = scroll_text[:max_length - 3] + "..."

        sys.stdout.write(TerminalControl.move_cursor(help_y, 2) + TerminalColors.BRIGHT_MAGENTA + help_text + TerminalColors.RESET)
        sys.stdout.write(TerminalControl.move_cursor(help_y + 1, 2) + TerminalColors.BRIGHT_MAGENTA + server_text + TerminalColors.RESET)
        sys.stdout.write(TerminalControl.move_cursor(help_y + 2, 2) + TerminalColors.BRIGHT_CYAN + scroll_text + TerminalColors.RESET)

    def draw_input_area(self):
        """Draw the command input area"""
        # Only update if command buffer has changed
        if hasattr(self, '_last_command_buffer') and self._last_command_buffer == self.command_buffer:
            return  # No change, skip drawing

        self._last_command_buffer = self.command_buffer

        input_y = self.max_y - 1

        # Calculate player list position
        player_list_x = self.max_x - 23  # Start 23 columns from right edge

        # Clear input area (only up to player list)
        sys.stdout.write(TerminalControl.move_cursor(input_y, 1) + TerminalControl.clear_line())

        # Draw input prompt and buffer
        prompt = " 💻 COMMAND: "
        max_length = player_list_x - len(prompt) - 3
        display_buffer = self.command_buffer[:max_length] if len(self.command_buffer) > max_length else self.command_buffer

        input_line = prompt + display_buffer
        if len(self.command_buffer) > len(display_buffer):
            input_line += "…"

        sys.stdout.write(TerminalControl.move_cursor(input_y, 2) + TerminalColors.BRIGHT_GREEN + input_line + TerminalColors.RESET)

        # Position cursor
        cursor_x = len(prompt) + len(self.command_buffer)
        if cursor_x < player_list_x - 1:
            sys.stdout.write(TerminalControl.move_cursor(input_y, cursor_x + 2))



    def handle_input(self) -> bool:
        """Handle user input, returns True if should continue"""
        try:
            # Handle incomplete escape sequences first
            if self.escape_buffer:
                return self.handle_incomplete_escape()

            # Non-blocking input check with shorter timeout
            if select.select([sys.stdin], [], [], 0.0001)[0]:
                key = sys.stdin.read(1)

                if not key:
                    return True

                if key == '\x1b':  # ESC sequence
                    # Handle escape sequences more robustly
                    return self.handle_escape_sequence()

                elif key == '\r' or key == '\n':  # Enter
                    self.process_command()
                    self.command_buffer = ""  # Clear immediately
                    return True

                elif key == '\x7f' or key == '\x08':  # Backspace
                    if self.command_buffer:
                        self.command_buffer = self.command_buffer[:-1]
                    return True

                elif key == '\x03':  # Ctrl+C
                    return False

                elif key == '\x1a':  # Ctrl+Z
                    return False

                elif key.isprintable():
                    # Limit command buffer size to prevent overflow
                    if len(self.command_buffer) < self.command_buffer_max:
                        self.command_buffer += key
                    return True

            return True

        except KeyboardInterrupt:
            return False
        except Exception as e:
            # Log the exception but don't crash
            print(f"\nInput error: {e}", file=sys.stderr)
            return True

    def handle_escape_sequence(self) -> bool:
        """Handle escape sequences more robustly"""
        try:
            # Read the next character with timeout
            if not select.select([sys.stdin], [], [], 0.001)[0]:
                # Store incomplete escape sequence for next iteration
                self.escape_buffer = '\x1b'
                return True

            next_char = sys.stdin.read(1)

            if next_char == '[':  # Control sequence
                return self.handle_control_sequence()
            elif next_char == 'O':  # Function key sequence
                return self.handle_function_key()
            elif next_char == 'M':  # Mouse event (disabled for SSH stability)
                return True  # Consume and ignore
            else:
                # Unknown escape sequence, clear buffer
                self.escape_buffer = ""
                return False

        except Exception:
            # Clear buffer on error
            self.escape_buffer = ""
            return False

    def handle_control_sequence(self) -> bool:
        """Handle control sequences like arrow keys, page up/down, etc."""
        try:
            # Read the sequence with timeout
            if not select.select([sys.stdin], [], [], 0.001)[0]:
                # Store incomplete sequence
                self.escape_buffer = '\x1b['
                return True

            seq = sys.stdin.read(1)

            if seq == 'A':  # Up arrow
                self.escape_buffer = ""
                self.scroll_log_up()
                return True
            elif seq == 'B':  # Down arrow
                self.escape_buffer = ""
                self.scroll_log_down()
                return True
            elif seq == '5':  # Page Up
                if select.select([sys.stdin], [], [], 0.001)[0]:
                    if sys.stdin.read(1) == '~':
                        self.escape_buffer = ""
                        self.scroll_log_page_up()
                        return True
                    else:
                        # Incomplete sequence
                        self.escape_buffer = '\x1b[5'
                        return True
                else:
                    # Incomplete sequence
                    self.escape_buffer = '\x1b[5'
                    return True
            elif seq == '6':  # Page Down
                if select.select([sys.stdin], [], [], 0.001)[0]:
                    if sys.stdin.read(1) == '~':
                        self.escape_buffer = ""
                        self.scroll_log_page_down()
                        return True
                    else:
                        # Incomplete sequence
                        self.escape_buffer = '\x1b[6'
                        return True
                else:
                    # Incomplete sequence
                    self.escape_buffer = '\x1b[6'
                    return True
            elif seq == 'H':  # Home
                self.escape_buffer = ""
                self.scroll_log_home()
                return True
            elif seq == 'F':  # End
                self.escape_buffer = ""
                self.scroll_log_end()
                return True

            # Unknown sequence, clear buffer
            self.escape_buffer = ""
            return False

        except Exception:
            self.escape_buffer = ""
            return False

    def handle_incomplete_escape(self) -> bool:
        """Handle incomplete escape sequences from previous iterations"""
        try:
            # Try to read more data for the incomplete sequence
            if not select.select([sys.stdin], [], [], 0.001)[0]:
                return True  # Still waiting for more data

            # Read one more character
            next_char = sys.stdin.read(1)
            self.escape_buffer += next_char

            # Process based on what we have so far
            if self.escape_buffer == '\x1b[':
                return self.handle_control_sequence()
            elif self.escape_buffer == '\x1bO':
                return self.handle_function_key()
            elif self.escape_buffer == '\x1bM':
                return True  # Consume and ignore mouse events
            elif self.escape_buffer.startswith('\x1b[5') or self.escape_buffer.startswith('\x1b[6'):
                # Continue reading for Page Up/Down
                if select.select([sys.stdin], [], [], 0.001)[0]:
                    final_char = sys.stdin.read(1)
                    if final_char == '~':
                        self.escape_buffer += final_char
                        if self.escape_buffer == '\x1b[5~':
                            self.scroll_log_page_up()
                        elif self.escape_buffer == '\x1b[6~':
                            self.scroll_log_page_down()
                        self.escape_buffer = ""
                        return True
                    else:
                        # Invalid sequence
                        self.escape_buffer = ""
                        return False
                else:
                    return True  # Still waiting
            else:
                # Unknown sequence, clear buffer
                self.escape_buffer = ""
                return False

        except Exception:
            self.escape_buffer = ""
            return False

    def handle_function_key(self) -> bool:
        """Handle function key sequences"""
        try:
            if not select.select([sys.stdin], [], [], 0.001)[0]:
                return False

            seq = sys.stdin.read(1)

            if seq == 'H':  # Home
                self.scroll_log_home()
                return True
            elif seq == 'F':  # End
                self.scroll_log_end()
                return True

            return False

        except Exception:
            return False

    def handle_simple_mouse(self) -> bool:
        """Mouse handling disabled for SSH stability"""
        # Mouse events are completely disabled to prevent crashes
        return True

    def process_command(self):
        """Process the entered command"""
        if not self.command_buffer.strip():
            return

        cmd = self.command_buffer.strip().lower()

        if cmd in ['start', 's']:
            if self.start_server():
                self.update_status()
                self.add_command_log("Server started successfully!")
            else:
                self.add_command_log("Failed to start server!")

        elif cmd in ['stop', 'st']:
            if self.stop_server():
                self.update_status()
                self.add_command_log("Server stopped successfully!")
            else:
                self.add_command_log("Failed to stop server!")

        elif cmd in ['restart', 'r']:
            # Non-blocking restart with background wait
            self.add_command_log("Restarting server...")
            # Start background thread to handle stop then start
            threading.Thread(target=self.restart_sequence, daemon=True).start()



        elif cmd in ['help', 'h']:
            self.add_command_log("Help requested - showing available commands")
            # Could show help popup
            pass

        elif cmd in ['players', 'p']:
            # Trigger immediate player count update before showing results
            self.add_command_log("Updating player count...")
            threading.Thread(target=self.trigger_player_update, daemon=True).start()

            # Wait a moment for the update to complete
            time.sleep(3)

            players = self.get_online_players_list()
            if players:
                player_list = ", ".join(players)
                self.add_command_log(f"Online players: {player_list}")
            else:
                self.add_command_log("No players currently online")

        elif cmd in ['loginfo', 'li']:
            with self.log_lock:
                total_lines = len(self.log_lines)
                visible_lines = self.max_y - 12  # Account for UI elements
                current_position = total_lines - visible_lines - self.scroll_offset if total_lines > visible_lines else 0
                self.add_command_log(f"Log: {total_lines} total lines, showing lines {current_position + 1}-{min(current_position + visible_lines, total_lines)}")

        elif cmd in ['quit', 'exit', 'q']:
            self.add_command_log("Quitting manager...")
            self.running = False

        elif cmd.startswith('/'):
            server_cmd = cmd[1:]
            if self.send_command(server_cmd):
                self.add_command_log(f"Server command sent: /{server_cmd}")
            else:
                self.add_command_log("Failed to send server command!")
        else:
            # Unknown command
            self.add_command_log(f"Unknown command: {cmd}")

    def cleanup(self):
        """Cleanup on exit"""
        self.stop_log_monitor()
        self.add_command_log("Manager cleanup completed")
        # Don't stop the server - let it keep running in background

    def signal_handler(self, signum, frame):
        """Handle termination signals"""
        self.add_command_log(f"Received signal {signum} - shutting down")
        self.running = False

    def run(self):
        """Main application loop"""
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)

        try:
            self.check_dependencies()
            self.setup_terminal()
            self.update_status()
            self.add_command_log("Terminal setup completed")
            self.start_log_monitor()
            self.add_command_log("Log monitoring started")

            while self.running:
                # Check for terminal resize
                self.check_terminal_resize()

                # Update status periodically
                self.update_status()

                # Draw UI continuously without fixed interval
                self.draw_header()
                self.draw_borders()
                self.draw_log_area()
                self.draw_player_list() # Draw player list
                self.draw_feedback_frame()
                self.draw_help_area()
                self.draw_input_area()

                sys.stdout.flush()

                # Handle input
                if not self.handle_input():
                    break

                # Shorter sleep for more responsive log updates
                time.sleep(0.001)  # 1ms for better responsiveness

        except Exception as e:
            print(f"Error: {e}")
            import traceback
            traceback.print_exc()

        finally:
            self.cleanup()
            self.restore_terminal()

    def strip_timestamp(self, line: str) -> str:
        """Strip timestamp prefix from log lines"""
        # Pattern: "1.8.2025 20:22:44 " or similar date/time formats

        # Match common timestamp patterns
        timestamp_patterns = [
            r'^\d{1,2}\.\d{1,2}\.\d{4}\s+\d{1,2}:\d{2}:\d{2}\s+',  # 1.8.2025 20:22:44
            r'^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+',          # 2025-01-08 20:22:44
            r'^\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}:\d{2}\s+',          # 01/08/2025 20:22:44
        ]

        for pattern in timestamp_patterns:
            if re.match(pattern, line):
                # Remove the timestamp and return the rest
                return re.sub(pattern, '', line)

        return line

def main():
    """Main entry point"""
    print("🚀 VintageStory Server Manager")
    print("Starting dependency check...")

    manager = VintageStoryServerManager()
    manager.run()

if __name__ == "__main__":
    main()
