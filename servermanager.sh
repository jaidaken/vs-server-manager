#!/usr/bin/env python3
import os
import sys
import time
import signal
import subprocess
import threading
import select
import termios
import tty
import fcntl
import struct
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
        # Configuration constants
        self.CONFIG = {
            "username": "vintagestory",
            "vs_path": "/home/vintagestory/server",
            "data_path": "/var/vintagestory/data",
            "screen_name": "vintagestory_server",
            "service": "VintagestoryServer.dll",
            "pid_file": "/tmp/vintagestory_server.pid",
            "log_subdir": "Logs",
            "log_filename": "server-main.log",
        }

        # Performance constants
        self.PERFORMANCE = {
            "target_fps": 30,
            "process_cache_interval": 0.5,
            "pid_cache_interval": 0.5,
            "cpu_update_interval": 1.0,
            "memory_update_interval": 1.0,
            "player_update_interval": 60.0,
            "memory_cleanup_interval": 300.0,
            "resource_check_interval": 60.0,
            "max_background_tasks": 3,
            "log_buffer_max_size": 10000,
            "command_log_max_size": 50,
            "memory_warning_threshold": 100,  # MB
            "log_buffer_warning_threshold": 7000,
            "command_log_warning_threshold": 35,
            "input_timeout": 0.001,  # 1ms timeout for input operations
            "input_timeout_fallback": 0.01,  # 10ms fallback if needed
        }

        # Error messages
        self.MESSAGES = {
            "server_started": "Server started successfully!",
            "server_start_failed": "Failed to start server!",
            "server_stopped": "Server stopped successfully!",
            "server_stop_failed": "Failed to stop server!",
            "server_restarted": "Server restarted successfully!",
            "server_restart_failed": "Failed to restart server!",
            "command_sent": "Server command sent: /{}",
            "command_failed": "Failed to send server command!",
            "unknown_command": "Unknown command: {}",
            "quitting": "Quitting manager...",
            "cleanup_completed": "Manager cleanup completed",
            "updating_players": "Updating player count...",
            "online_players": "Online players: {}",
            "no_players": "No players currently online",
            "player_count_update": "Manual player count update: {} players",
            "initial_player_check": "Performing initial player count check...",
            "no_initial_check": "Server not running - no initial player check needed",
            "high_memory_usage": "High memory usage: {:.1f}MB",
            "large_log_buffer": "Large log buffer: {} lines",
            "large_command_log": "Large command log: {} entries",
        }

        # Configuration
        self.username = self.CONFIG["username"]
        self.vs_path = self.CONFIG["vs_path"]
        self.data_path = self.CONFIG["data_path"]
        self.screen_name = self.CONFIG["screen_name"]
        self.service = self.CONFIG["service"]
        self.pid_file = self.CONFIG["pid_file"]
        self.log_file = os.path.join(
            self.data_path, self.CONFIG["log_subdir"], self.CONFIG["log_filename"]
        )

        # Performance settings
        self.target_fps = self.PERFORMANCE["target_fps"]
        self.frame_time = 1.0 / self.target_fps
        self.last_frame_time = 0

        # UI state
        self.terminal_fd = sys.stdin.fileno()
        self.old_terminal_settings = None
        self.max_y, self.max_x = 0, 0
        self.log_lines = deque(maxlen=self.PERFORMANCE["log_buffer_max_size"])
        self.command_buffer = ""
        self.command_buffer_max = 1024
        self.status = "OFF"
        self.last_log_size = 0
        self.running = True
        self.cursor_visible = True
        self.scroll_offset = 0

        # Caching system for performance
        self._process_info_cache = None
        self._process_info_cache_time = 0
        self._process_info_cache_interval = self.PERFORMANCE["process_cache_interval"]

        # CPU monitoring state with caching
        self.last_cpu_update = 0
        self.cached_cpu_percent = "N/A"
        self.cpu_update_interval = self.PERFORMANCE["cpu_update_interval"]

        # Memory monitoring state with caching
        self.last_mem_update = 0
        self.cached_mem_percent = "N/A"
        self.mem_update_interval = self.PERFORMANCE["memory_update_interval"]

        # PID monitoring state with caching
        self.cached_pid = None
        self.pid_update_needed = True
        self._pid_cache_time = 0
        self._pid_cache_interval = self.PERFORMANCE["pid_cache_interval"]

        # Command log system
        self.command_log = deque(maxlen=self.PERFORMANCE["command_log_max_size"])
        self.command_log.append("Manager started - Ready for commands")

        # Security tracking
        self.security_events = deque(maxlen=100)  # Track security events
        self.failed_commands = 0  # Track failed command attempts
        self.last_security_check = 0

        # Player tracking system
        self.connected_players = set()
        self.player_count = 0
        self.last_player_update = 0
        self.player_update_interval = self.PERFORMANCE["player_update_interval"]
        self.player_update_thread = None
        self.player_update_running = True

        # Log color tracking
        self.last_log_color = TerminalColors.WHITE

        # Threading for log monitoring
        self.log_thread = None
        self.log_thread_running = True
        self.log_lock = threading.Lock()

        # Thread synchronization
        self._shutdown_event = threading.Event()
        self._player_update_lock = threading.Lock()
        self._command_lock = threading.Lock()

        # Thread pool for background tasks
        self._background_tasks = []
        self._max_background_tasks = self.PERFORMANCE["max_background_tasks"]

        # Input handling state - Simplified
        self.escape_buffer = ""
        self.input_timeout = self.PERFORMANCE["input_timeout"]
        self.input_timeout_fallback = self.PERFORMANCE["input_timeout_fallback"]

        # Mouse support detection
        self.mouse_supported = False
        self.mouse_enabled = False

        # Redraw optimization flags
        self._needs_redraw = True
        self._last_status = None
        self._last_pid = None
        self._last_cpu = None
        self._last_mem = None

        # UI state tracking for dirty region optimization
        self._dirty_regions = set()  # Track which areas need redrawing
        self._last_terminal_size = (0, 0)
        self._last_player_count = 0
        self._last_player_list = []
        self._last_log_content = ""
        self._last_command_content = ""
        self._last_command_buffer = ""  # Initialize command buffer tracking

        # Mark all regions as dirty on startup for initial draw
        self._dirty_regions = {
            "header",
            "borders",
            "log",
            "players",
            "feedback",
            "help",
            "input",
        }

        # Memory management
        self._last_memory_cleanup = 0
        self._memory_cleanup_interval = self.PERFORMANCE["memory_cleanup_interval"]

        # Resource monitoring
        self._last_resource_check = 0
        self._resource_check_interval = self.PERFORMANCE["resource_check_interval"]
        self._memory_usage_mb = 0
        self._log_lines_count = 0

        # Input handling - Simplified escape sequence mapping
        self.ESCAPE_SEQUENCES = {
            # Arrow keys
            "\x1b[A": "scroll_up",
            "\x1b[B": "scroll_down",
            "\x1b[C": "ignore",  # Right arrow
            "\x1b[D": "ignore",  # Left arrow
            # Page navigation
            "\x1b[5~": "page_up",
            "\x1b[6~": "page_down",
            # Home/End
            "\x1b[H": "home",
            "\x1b[F": "end",
            "\x1bOH": "home",  # Alternative Home
            "\x1bOF": "end",  # Alternative End
        }

        # Security validation patterns
        self.SECURITY_PATTERNS = {
            "screen_name": r"^[a-zA-Z0-9_-]+$",  # Alphanumeric, underscore, hyphen only
            "command": r'^[a-zA-Z0-9\s\-_.,!?()[\]{}:;"\'\\/]+$',  # Safe command characters
            "path": r"^[a-zA-Z0-9\-_./]+$",  # Safe path characters
        }

        # Dangerous command patterns to block
        self.DANGEROUS_PATTERNS = [
            r"sudo\s+",  # sudo commands
            r"rm\s+-rf",  # recursive delete
            r"dd\s+if=",  # disk operations
            r">\s*/dev/",  # device writes
            r"chmod\s+777",  # dangerous permissions
            r"wget\s+http",  # downloads
            r"curl\s+http",  # downloads
            r"nc\s+",  # netcat
            r"telnet\s+",  # telnet
            r"ssh\s+",  # ssh connections
        ]

    def get_terminal_size(self) -> Tuple[int, int]:
        """Get terminal dimensions"""
        try:
            hw = struct.unpack(
                "hh", fcntl.ioctl(self.terminal_fd, termios.TIOCGWINSZ, "1234")
            )
            return hw[0], hw[1]  # rows, cols
        except (OSError, IOError, struct.error):
            # Terminal size detection failed, use fallback
            return 24, 80  # fallback

    def check_terminal_resize(self):
        """Check if terminal size has changed and reset drawn flags if needed"""
        new_size = self.get_terminal_size()
        if new_size != (self.max_y, self.max_x):
            self.max_y, self.max_x = new_size
            # Force complete redraw when terminal size changes
            self.force_redraw()
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
            termios.tcsetattr(
                self.terminal_fd, termios.TCSADRAIN, self.old_terminal_settings
            )

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
            "pgrep": "procps",
            "screen": "screen",
            "dotnet": ".NET Runtime",
            "bash": "bash",
            "ps": "procps",
        }
        missing_commands = []

        for cmd, package in required_commands.items():
            try:
                result = subprocess.run(["which", cmd], capture_output=True)
                if result.returncode != 0:
                    missing_commands.append((cmd, package))
            except subprocess.CalledProcessError:
                missing_commands.append((cmd, package))

        # Check Python modules
        missing_builtin = []
        builtin_modules = [
            "os",
            "sys",
            "time",
            "signal",
            "subprocess",
            "threading",
            "json",
            "select",
            "termios",
            "tty",
            "fcntl",
            "struct",
            "pathlib",
            "typing",
            "collections",
            "re",
        ]

        for module in builtin_modules:
            try:
                __import__(module)
            except ImportError:
                missing_builtin.append(module)
            except Exception as e:
                # Unexpected error importing module
                print(f"Warning: Error importing {module}: {e}", file=sys.stderr)
                missing_builtin.append(module)

        # Check terminal capabilities
        terminal_issues = []
        if not sys.stdout.isatty():
            terminal_issues.append("Not running in a terminal")

        term = os.environ.get("TERM", "")
        if not term or term == "dumb":
            terminal_issues.append(
                "Unsupported terminal type (set TERM=xterm-256color)"
            )

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
            print(
                "Press Enter to continue anyway, or Ctrl+C to exit and install dependencies..."
            )

            try:
                input()
            except KeyboardInterrupt:
                print("\n❌ Exiting. Please install dependencies and try again.")
                sys.exit(1)
        else:
            print("✅ All dependencies satisfied!")

    def get_process_info(self) -> Dict[str, Any]:
        """Get current process information with caching"""
        current_time = time.time()

        # Return cached result if still valid
        if (
            self._process_info_cache is not None
            and current_time - self._process_info_cache_time
            < self._process_info_cache_interval
        ):
            return self._process_info_cache

        # Check running processes - look for actual dotnet process
        running_pids = []

        try:
            # First, get all dotnet processes
            result = subprocess.run(
                ["pgrep", "-f", "dotnet.*VintagestoryServer.dll"],
                capture_output=True,
                text=True,
                timeout=1.0,  # Add timeout
            )
            if result.returncode == 0:
                # Get the actual dotnet process PIDs
                dotnet_pids = [
                    int(pid) for pid in result.stdout.strip().split("\n") if pid
                ]

                # Filter to only dotnet processes (not screen processes)
                for pid in dotnet_pids:
                    try:
                        # Check if this PID is actually a dotnet process
                        with open(f"/proc/{pid}/comm", "r") as f:
                            comm = f.read().strip()
                        if comm == "dotnet":
                            running_pids.append(pid)
                    except (FileNotFoundError, PermissionError):
                        continue
        except (ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass

        # Also check for screen session
        screen_running = False
        try:
            result = subprocess.run(
                ["screen", "-list", self.screen_name],
                capture_output=True,
                text=True,
                timeout=1.0,  # Add timeout
            )
            screen_running = (
                result.returncode == 0 and self.screen_name in result.stdout
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass

        # Cache the result
        result = {
            "running_pids": running_pids,
            "screen_running": screen_running,
            "is_running": len(running_pids) > 0 or screen_running,
        }

        self._process_info_cache = result
        self._process_info_cache_time = current_time

        return result

    def update_status(self):
        """Update server status"""
        process_info = self.get_process_info()
        old_status = self.status
        self.status = "ON" if process_info["is_running"] else "OFF"

        # If status changed, invalidate caches and force redraw
        if old_status != self.status:
            self.invalidate_caches()
            self.mark_dirty("header")  # Header needs redraw when status changes

        # If server just started (status changed from OFF to ON), trigger immediate player update
        if old_status == "OFF" and self.status == "ON":
            # Trigger immediate player count update using thread pool
            self.start_background_task(self.trigger_player_update)

    def trigger_player_update(self):
        """Trigger an immediate player count update"""

        def _do_player_update():
            with self._player_update_lock:
                if self.get_process_info()["is_running"]:
                    if self.send_command("list clients"):
                        time.sleep(0.5)  # Reduced wait time for command processing
                        self.parse_list_clients_output()
                        self.add_command_log(
                            self.MESSAGES["player_count_update"].format(
                                len(self.connected_players)
                            )
                        )

        # Use thread pool instead of creating new thread every time
        self.start_background_task(_do_player_update)

    def get_pid(self) -> Optional[int]:
        """Get cached PID, updating only when needed"""
        current_time = time.time()

        # Return cached PID if still valid
        if (
            self.cached_pid is not None
            and current_time - self._pid_cache_time < self._pid_cache_interval
        ):
            return self.cached_pid

        if self.pid_update_needed:
            if hasattr(self, "_pid_delay_needed"):
                # Wait 1 second before updating PID (for manual start)
                time.sleep(1)
                delattr(self, "_pid_delay_needed")
            else:
                # Immediate update (for script startup)
                pass

            process_info = self.get_process_info()
            if process_info["running_pids"]:
                self.cached_pid = process_info["running_pids"][0]
            else:
                self.cached_pid = None
            self.pid_update_needed = False
            self._pid_cache_time = current_time

        return self.cached_pid

    def start_server(self) -> bool:
        """Start the VintageStory server (like old UI)"""
        return self.safe_execute(self._start_server_impl)

    def _start_server_impl(self) -> bool:
        """Implementation of server start with error handling"""
        if self.get_process_info()["is_running"]:
            return True

        # Validate configuration parameters for security
        if not self.validate_input(self.screen_name, "screen_name"):
            self.log_security_event(
                "INVALID_SCREEN_NAME",
                f"Screen name contains invalid characters: {self.screen_name}",
            )
            return False

        if not self.validate_input(self.data_path, "path"):
            self.log_security_event(
                "INVALID_DATA_PATH",
                f"Data path contains invalid characters: {self.data_path}",
            )
            return False

        # Check if service file exists
        service_path = os.path.join(self.vs_path, self.service)
        if not os.path.exists(service_path):
            self.log_error(f"Service file not found: {service_path}")
            return False

        # Create data path if it doesn't exist
        try:
            os.makedirs(self.data_path, exist_ok=True)
        except Exception as e:
            self.log_error(f"Failed to create data directory: {self.data_path}", e)
            return False

        # Start server with secure subprocess call
        try:
            # Use direct subprocess call instead of bash -c to prevent shell injection
            subprocess.run(
                [
                    "screen",
                    "-h",
                    "1024",
                    "-dmS",
                    self.screen_name,
                    "dotnet",
                    self.service,
                    "--dataPath",
                    self.data_path,
                ],
                check=True,
                timeout=10.0,
            )
            # Mark PID for update after 2 seconds (manual start)
            self.pid_update_needed = True
            self._pid_delay_needed = True

            # Force log refresh after server start to catch initial lines
            self.start_background_task(self.force_log_refresh)

            # Non-blocking: return immediately, status will be updated in main loop
            return True
        except subprocess.CalledProcessError as e:
            self.log_error("Failed to start server with screen", e)
        except subprocess.TimeoutExpired as e:
            self.log_error("Server start command timed out", e)
        except Exception as e:
            self.log_error("Unexpected error starting server", e)

        return False

    def stop_server(self) -> bool:
        """Stop the VintageStory server gracefully (like old UI)"""
        return self.safe_execute(self._stop_server_impl)

    def _stop_server_impl(self) -> bool:
        """Implementation of server stop with error handling"""
        process_info = self.get_process_info()
        if not process_info["is_running"]:
            return True

        try:
            # Simply send the stop command to the server (like old UI)
            return self.send_command("stop")
        except Exception as e:
            self.log_error("Failed to stop server", e)
            return False

    def send_command(self, command: str) -> bool:
        """Send a command to the server with security validation"""
        if not self.get_process_info()["is_running"]:
            return False

        # Validate and sanitize the command
        if not self.validate_input(command, "command"):
            self.log_security_event(
                "INVALID_COMMAND", f"Rejected command: {command[:50]}..."
            )
            return False

        sanitized_command = self.sanitize_command(command)
        if sanitized_command != command:
            self.log_security_event(
                "COMMAND_SANITIZED",
                f"Original: {command[:50]}... -> Sanitized: {sanitized_command[:50]}...",
            )

        try:
            # Use direct subprocess call instead of bash -c to prevent shell injection
            # Escape the command properly for screen
            escaped_command = sanitized_command.replace('"', '\\"').replace("'", "\\'")
            subprocess.run(
                [
                    "screen",
                    "-p",
                    "0",
                    "-S",
                    self.screen_name,
                    "-X",
                    "eval",
                    f'stuff "/{escaped_command}"\\015',
                ],
                check=True,
            )
            return True
        except subprocess.CalledProcessError:
            return False

    def add_command_log(self, message: str):
        """Add a message to the command log with thread safety"""
        timestamp = time.strftime("%H:%M:%S")
        with self._command_lock:
            self.command_log.append(f"[{timestamp}] {message}")
        self.mark_dirty(
            "feedback"
        )  # Feedback frame needs redraw when command log changes

    def force_log_refresh(self):
        """Force a complete log refresh to catch any missed lines"""
        time.sleep(0.5)  # Reduced wait time for server to start writing logs
        try:
            if os.path.exists(self.log_file):
                with open(self.log_file, "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read()
                    if content:
                        lines = content.splitlines()
                        with self.log_lock:
                            self.log_lines.clear()
                            self.log_lines.extend(lines)
                        self.last_log_size = os.path.getsize(self.log_file)
        except (IOError, OSError, UnicodeDecodeError) as e:
            print(f"Force log refresh error: {e}", file=sys.stderr)
        except Exception as e:
            print(f"Unexpected force log refresh error: {e}", file=sys.stderr)

    def restart_sequence(self):
        """Background thread for restart sequence with proper locking"""
        with self._command_lock:
            # Send stop command
            self.stop_server()

            # Wait for server to stop (checking periodically instead of fixed sleep)
            wait_time = 0
            max_wait = 15  # Maximum 15 seconds wait
            while wait_time < max_wait and self.get_process_info()["is_running"]:
                time.sleep(0.5)  # Check every 500ms
                wait_time += 0.5

            # Start new server
            if self.start_server():
                self.update_status()
                self.add_command_log(self.MESSAGES["server_restarted"])
            else:
                self.add_command_log(self.MESSAGES["server_restart_failed"])

    def log_monitor_thread(self):
        """Background thread that continuously monitors the log file with optimized I/O"""
        # Read existing log content on startup (only last 1000 lines to prevent memory issues)
        if os.path.exists(self.log_file):
            try:
                file_size = os.path.getsize(self.log_file)
                # Read only last 50KB to get recent lines
                read_size = min(50000, file_size)

                with open(self.log_file, "r", encoding="utf-8", errors="ignore") as f:
                    if file_size > read_size:
                        f.seek(max(0, file_size - read_size))
                        # Read a bit more to ensure complete lines
                        existing_content = f.read(read_size + 1024)
                    else:
                        existing_content = f.read()

                    self.last_log_size = file_size

                    if existing_content:
                        existing_lines = existing_content.splitlines()
                        # Only keep the last 1000 lines to prevent memory bloat
                        if len(existing_lines) > 1000:
                            existing_lines = existing_lines[-1000:]

                        with self.log_lock:
                            self.log_lines.extend(existing_lines)

            except Exception as e:
                print(f"Error reading existing log: {e}", file=sys.stderr)

        # File monitoring with reduced I/O frequency
        check_interval = 0.1  # Check every 100ms instead of 1ms
        last_check = 0

        while self.log_thread_running:
            try:
                current_time = time.time()

                # Only check file if enough time has passed
                if current_time - last_check < check_interval:
                    time.sleep(0.01)  # Sleep 10ms between checks
                    continue

                last_check = current_time

                if os.path.exists(self.log_file):
                    current_size = os.path.getsize(self.log_file)

                    if current_size > self.last_log_size:
                        # Read only new content
                        try:
                            with open(
                                self.log_file, "r", encoding="utf-8", errors="ignore"
                            ) as f:
                                f.seek(self.last_log_size)
                                new_content = f.read()

                                if new_content:
                                    new_lines = new_content.splitlines()
                                    with self.log_lock:
                                        self.log_lines.extend(new_lines)
                                        self.mark_dirty("log")  # Log area needs redraw

                                # Update size after successful read
                                self.last_log_size = current_size

                        except (IOError, OSError):
                            # If file read fails, try to recover by reading from beginning
                            try:
                                with open(
                                    self.log_file,
                                    "r",
                                    encoding="utf-8",
                                    errors="ignore",
                                ) as f:
                                    new_content = f.read()
                                    if new_content:
                                        new_lines = new_content.splitlines()
                                        with self.log_lock:
                                            self.log_lines.clear()
                                            self.log_lines.extend(new_lines)
                                            self.mark_dirty(
                                                "log"
                                            )  # Log area needs redraw
                                        self.last_log_size = current_size
                            except (IOError, OSError, UnicodeDecodeError):
                                # Log file read error, continue monitoring
                                pass

                    elif current_size < self.last_log_size:
                        # Log file was truncated or rotated
                        try:
                            with open(
                                self.log_file, "r", encoding="utf-8", errors="ignore"
                            ) as f:
                                new_content = f.read()
                                if new_content:
                                    new_lines = new_content.splitlines()
                                    with self.log_lock:
                                        self.log_lines.clear()
                                        self.log_lines.extend(new_lines)
                                        self.mark_dirty("log")  # Log area needs redraw
                                    self.last_log_size = current_size
                        except (IOError, OSError, UnicodeDecodeError):
                            # Log file read error, continue monitoring
                            pass

                # Sleep between checks to reduce CPU usage
                time.sleep(check_interval)

            except (IOError, OSError):
                time.sleep(check_interval)
            except Exception:
                time.sleep(check_interval)

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

        # Wait for background tasks to complete
        self.wait_for_background_tasks(timeout=2.0)

    def get_cpu_percentage(self) -> str:
        """Get CPU percentage for the dotnet process, with caching"""
        current_time = time.time()

        # Check if we need to update (every second)
        if current_time - self.last_cpu_update >= self.cpu_update_interval:
            cached_pid = self.get_pid()

            if cached_pid is not None:
                try:
                    result = subprocess.run(
                        ["ps", "-p", str(cached_pid), "-o", "%cpu"],
                        capture_output=True,
                        text=True,
                        timeout=1.0,
                    )
                    if result.returncode == 0:
                        lines = result.stdout.strip().split("\n")
                        if len(lines) >= 2:
                            self.cached_cpu_percent = lines[1].strip()
                        else:
                            self.cached_cpu_percent = "N/A"
                    else:
                        self.cached_cpu_percent = "N/A"
                except (
                    subprocess.CalledProcessError,
                    ValueError,
                    subprocess.TimeoutExpired,
                ):
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
                        ["ps", "-p", str(cached_pid), "-o", "%mem"],
                        capture_output=True,
                        text=True,
                        timeout=1.0,
                    )
                    if result.returncode == 0:
                        lines = result.stdout.strip().split("\n")
                        if len(lines) >= 2:
                            self.cached_mem_percent = lines[1].strip()
                        else:
                            self.cached_mem_percent = "N/A"
                    else:
                        self.cached_mem_percent = "N/A"
                except (
                    subprocess.CalledProcessError,
                    ValueError,
                    subprocess.TimeoutExpired,
                ):
                    self.cached_mem_percent = "N/A"
            else:
                self.cached_mem_percent = "N/A"

            self.last_mem_update = current_time

        return self.cached_mem_percent

    def get_player_count(self) -> str:
        """Get current player count, with caching and thread safety"""
        current_time = time.time()

        # Check if we need to update (every 60 seconds)
        if current_time - self.last_player_update >= self.player_update_interval:
            # Update player count from connected players set
            with self._player_update_lock:
                self.player_count = len(self.connected_players)
            self.last_player_update = current_time

        return str(self.player_count)

    def player_update_thread(self):
        """Background thread that updates player count every minute with reduced resource usage"""
        last_server_check = 0
        server_check_interval = 10.0  # Check server status every 10 seconds

        while self.player_update_running:
            try:
                current_time = time.time()

                # Only check server status periodically to reduce subprocess calls
                if current_time - last_server_check >= server_check_interval:
                    server_running = self.get_process_info()["is_running"]
                    last_server_check = current_time
                else:
                    # Use cached server status
                    server_running = self.status == "ON"

                if server_running:
                    # Send /list clients command to get current players
                    if self.send_command("list clients"):
                        # Wait a moment for the command to be processed
                        time.sleep(0.5)
                        # Parse the log for the /list clients output
                        self.parse_list_clients_output()
                else:
                    # Server not running, clear player list
                    self.connected_players.clear()
                    self.player_count = 0
                    self.mark_dirty("players")  # Player list needs redraw

                # Sleep for the update interval
                time.sleep(self.player_update_interval)

            except (IOError, OSError) as e:
                # File I/O error in player update
                print(f"Player update I/O error: {e}", file=sys.stderr)
                time.sleep(5)  # Reduced sleep on error
            except Exception as e:
                # Unexpected error in player update
                print(f"Player update unexpected error: {e}", file=sys.stderr)
                time.sleep(5)  # Reduced sleep on error

    def start_player_update_thread(self):
        """Start the background player update thread"""
        self.player_update_thread = threading.Thread(
            target=self.player_update_thread, daemon=True
        )
        self.player_update_thread.start()

        # Do an initial player count check after a short delay
        threading.Thread(target=self.initial_player_check, daemon=True).start()

    def initial_player_check(self):
        """Initial player count check when script starts"""
        # Check if server is running and do initial player count immediately
        if self.get_process_info()["is_running"]:
            self.add_command_log(self.MESSAGES["initial_player_check"])
            # Use the same trigger method for consistency
            self.trigger_player_update()
        else:
            self.add_command_log(self.MESSAGES["no_initial_check"])

    def stop_player_update_thread(self):
        """Stop the background player update thread"""
        self.player_update_running = False
        if self.player_update_thread and self.player_update_thread.is_alive():
            self.player_update_thread.join(timeout=1.0)

    def parse_list_clients_output(self):
        """Parse the log for /list clients output with efficient file reading"""
        try:
            if not os.path.exists(self.log_file):
                return

            # Get file size for efficient reading
            file_size = os.path.getsize(self.log_file)

            # Read only the last 2KB of the file instead of entire file
            chunk_size = 2048
            with open(self.log_file, "r", encoding="utf-8", errors="ignore") as f:
                if file_size > chunk_size:
                    f.seek(max(0, file_size - chunk_size))
                    # Read a bit more to ensure we get complete lines
                    content = f.read(chunk_size + 1024)
                else:
                    content = f.read()

            # Split into lines and take the last 50 lines
            lines = content.splitlines()
            recent_lines = lines[-50:] if len(lines) > 50 else lines

            # Clear current players
            self.connected_players.clear()

            # Look for /list clients output
            for line in recent_lines:
                line = line.strip()

                # Handle /list clients output format: "[2] Jaidaken [::ffff:192.168.1.239]:55786"
                if (
                    line.startswith("[")
                    and "] " in line
                    and "[" in line[line.find("] ") + 2 :]
                ):
                    try:
                        # Extract player name between "] " and " ["
                        parts = line.split("] ")
                        if len(parts) >= 2:
                            player_part = parts[1]
                            if " [" in player_part:
                                player_name = player_part.split(" [")[0].strip()
                                if (
                                    player_name
                                    and player_name not in self.connected_players
                                ):
                                    self.connected_players.add(player_name)
                    except Exception:
                        pass  # Skip malformed lines

                        # Update player count
            self.player_count = len(self.connected_players)
            self.mark_dirty("players")  # Player list needs redraw

        except (IOError, OSError, UnicodeDecodeError) as e:
            # Log file read error
            print(f"Parse list clients file error: {e}", file=sys.stderr)
        except Exception as e:
            # Unexpected error in parsing
            print(f"Parse list clients parsing error: {e}", file=sys.stderr)

    def get_online_players_list(self) -> List[str]:
        """Get list of currently online players with thread safety"""
        with self._player_update_lock:
            return list(self.connected_players)

    def draw_header(self):
        """Draw the header with title and status using optimized string formatting"""
        try:
            # Check if header needs redrawing
            if not self.is_dirty("header"):
                return

            # Get current values for comparison
            current_status = self.status
            cached_pid = self.get_pid()
            cpu_percent = self.get_cpu_percentage()
            mem_percent = self.get_memory_percentage()

            # Check if we need to redraw (only if values changed)
            current_values = (current_status, cached_pid, cpu_percent, mem_percent)
            if self._last_status == current_values and not self._needs_redraw:
                self.clear_dirty("header")
                return  # No change, skip drawing

            self._last_status = current_values

            # Use string formatting for better performance
            title = " VINTAGESTORY SERVER MANAGER "
            status_text = "● RUNNING" if self.status == "ON" else "● STOPPED"

            if cached_pid is not None:
                pid_text = f" 🖥️ PID: {cached_pid}"
                cpu_text = f" 📊 CPU: {cpu_percent}%"
                mem_text = f" 💾 MEM: {mem_percent}%"
            else:
                pid_text = " 🖥️ PID: N/A"
                cpu_text = " 📊 CPU: N/A"
                mem_text = " 💾 MEM: N/A"

            # Calculate positions using string formatting
            title_start = 2
            status_start = (
                self.max_x
                - len(status_text)
                - len(pid_text)
                - len(cpu_text)
                - len(mem_text)
                - 2
            )

            # Build header using string formatting instead of concatenation
            header_parts = [
                (" " * title_start, TerminalColors.BRIGHT_CYAN),
                (title, TerminalColors.BRIGHT_WHITE),
                (
                    " " * (status_start - title_start - len(title)),
                    TerminalColors.BRIGHT_CYAN,
                ),
                (
                    status_text,
                    TerminalColors.BRIGHT_GREEN
                    if self.status == "ON"
                    else TerminalColors.BRIGHT_RED,
                ),
                (
                    pid_text,
                    TerminalColors.BRIGHT_YELLOW
                    if cached_pid is not None
                    else TerminalColors.BRIGHT_BLACK,
                ),
                (
                    cpu_text,
                    TerminalColors.BRIGHT_MAGENTA
                    if cached_pid is not None
                    else TerminalColors.BRIGHT_BLACK,
                ),
                (
                    mem_text,
                    TerminalColors.BRIGHT_CYAN
                    if cached_pid is not None
                    else TerminalColors.BRIGHT_BLACK,
                ),
                (
                    " "
                    * (
                        self.max_x
                        - status_start
                        - len(status_text)
                        - len(pid_text)
                        - len(cpu_text)
                        - len(mem_text)
                    ),
                    TerminalColors.BRIGHT_CYAN,
                ),
            ]

            # Build colored header efficiently
            colored_header = (
                "".join(color + text for text, color in header_parts)
                + TerminalColors.RESET
            )

            sys.stdout.write(TerminalControl.move_cursor(1, 1) + colored_header)
            self.clear_dirty("header")
        except (OSError, IOError):
            # Terminal I/O error in header drawing
            sys.stdout.write(
                TerminalControl.move_cursor(1, 1) + "VINTAGESTORY SERVER MANAGER"
            )
            self.clear_dirty("header")
        except Exception:
            # Unexpected error in header drawing
            sys.stdout.write(
                TerminalControl.move_cursor(1, 1) + "VINTAGESTORY SERVER MANAGER"
            )
            self.clear_dirty("header")

    def draw_feedback_frame(self):
        """Draw the command log frame between log and help areas with dirty region tracking"""
        # Check if feedback frame needs redrawing
        if not self.is_dirty("feedback"):
            return

        # Calculate command log area position
        log_y = self.max_y - 6  # Between log and help areas

        # Calculate player list position
        player_list_x = self.max_x - 23  # Start 23 columns from right edge

        # Check if we need to update (only if command log has changed)
        with self._command_lock:
            if self.command_log:
                latest_message = list(self.command_log)[-1]
            else:
                latest_message = ""

        # Check if command content changed
        if latest_message == self._last_command_content and not self._needs_redraw:
            self.clear_dirty("feedback")
            return  # No change, skip drawing

        self._last_command_content = latest_message

        # Clear command log area (only up to player list)
        sys.stdout.write(
            TerminalControl.move_cursor(log_y + 1, 1) + TerminalControl.clear_line()
        )

        # Show the most recent command log entry
        with self._command_lock:
            if self.command_log:
                latest_message = list(self.command_log)[-1]
                # Truncate if too long (account for player list)
                max_length = player_list_x - 4
                if len(latest_message) > max_length:
                    latest_message = latest_message[: max_length - 3] + "..."

                message_x = max(2, (player_list_x - len(latest_message)) // 2)
                sys.stdout.write(
                    TerminalControl.move_cursor(log_y + 1, message_x)
                    + TerminalColors.BRIGHT_CYAN
                    + latest_message
                    + TerminalColors.RESET
                )

        self.clear_dirty("feedback")

    def draw_borders(self):
        """Draw simple borders around each section with dirty region tracking"""
        # Check if borders need redrawing
        if not self.is_dirty("borders"):
            return

        # Check if terminal size changed
        current_size = (self.max_y, self.max_x)
        if current_size != self._last_terminal_size:
            self._last_terminal_size = current_size
        elif not self._needs_redraw:
            self.clear_dirty("borders")
            return

        # Simple border function
        def draw_box(x, y, width, height):
            # Top and bottom
            for i in range(width):
                sys.stdout.write(
                    TerminalControl.move_cursor(y, x + i)
                    + TerminalColors.BRIGHT_BLUE
                    + "-"
                    + TerminalColors.RESET
                )
                sys.stdout.write(
                    TerminalControl.move_cursor(y + height - 1, x + i)
                    + TerminalColors.BRIGHT_BLUE
                    + "-"
                    + TerminalColors.RESET
                )
            # Left and right
            for i in range(height):
                sys.stdout.write(
                    TerminalControl.move_cursor(y + i, x)
                    + TerminalColors.BRIGHT_BLUE
                    + "|"
                    + TerminalColors.RESET
                )
                sys.stdout.write(
                    TerminalControl.move_cursor(y + i, x + width - 1)
                    + TerminalColors.BRIGHT_BLUE
                    + "|"
                    + TerminalColors.RESET
                )
            # Corners
            sys.stdout.write(
                TerminalControl.move_cursor(y, x)
                + TerminalColors.BRIGHT_BLUE
                + "+"
                + TerminalColors.RESET
            )
            sys.stdout.write(
                TerminalControl.move_cursor(y, x + width - 1)
                + TerminalColors.BRIGHT_BLUE
                + "+"
                + TerminalColors.RESET
            )
            sys.stdout.write(
                TerminalControl.move_cursor(y + height - 1, x)
                + TerminalColors.BRIGHT_BLUE
                + "+"
                + TerminalColors.RESET
            )
            sys.stdout.write(
                TerminalControl.move_cursor(y + height - 1, x + width - 1)
                + TerminalColors.BRIGHT_BLUE
                + "+"
                + TerminalColors.RESET
            )

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
        """Draw the log display area with color coding and line wrapping using dirty region tracking"""
        # Check if log area needs redrawing
        if not self.is_dirty("log"):
            return

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

        # Check if log content changed
        current_content = "".join(display_lines)
        if current_content == self._last_log_content and not self._needs_redraw:
            self.clear_dirty("log")
            return  # No change, skip drawing

        self._last_log_content = current_content

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
            if not line.startswith(" ") and not line.startswith("\t"):
                self.last_log_color = color

            # Wrap long lines (account for border)
            wrapped_lines = self.wrap_line(
                clean_line, log_width - 3
            )  # -3 for border spacing

            for wrapped_line in wrapped_lines:
                if current_y >= log_end_y or lines_drawn >= log_height:
                    break

                # Truncate if still too long
                display_line = (
                    wrapped_line[: log_width - 3]
                    if len(wrapped_line) > log_width - 3
                    else wrapped_line
                )

                # Draw with proper spacing from left border
                sys.stdout.write(
                    TerminalControl.move_cursor(current_y, 2)
                    + color
                    + display_line
                    + TerminalColors.RESET
                )
                current_y += 1
                lines_drawn += 1

        self.clear_dirty("log")

    def get_log_line_color(self, line: str) -> str:
        """Get color for log line based on its type"""
        line_upper = line.upper()

        # Check for indented lines first (stack traces, etc.)
        if line.startswith(" ") or line.startswith("\t"):
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
        elif (
            line.strip().startswith("[")
            and "] " in line
            and "[" in line[line.find("] ") + 2 :]
        ):
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
        """Draw the player list panel on the right side with dirty region tracking"""
        # Check if player list needs redrawing
        if not self.is_dirty("players"):
            return

        # Get current players
        players = self.get_online_players_list()
        player_count = len(players)

        # Check if player data changed
        if (
            player_count == self._last_player_count
            and players == self._last_player_list
            and not self._needs_redraw
        ):
            self.clear_dirty("players")
            return

        self._last_player_count = player_count
        self._last_player_list = players.copy()

        # Calculate player list position and size - full height
        player_list_x = self.max_x - 23  # Start 23 columns from right edge
        player_list_width = 21  # 21 columns wide
        player_list_start_y = 2  # Start at the top border (row 2)
        player_list_end_y = self.max_y  # End at the bottom border (row self.max_y)

        # Draw title
        title = " 👥 PLAYERS "
        title_x = player_list_x + (player_list_width - len(title)) // 2
        sys.stdout.write(
            TerminalControl.move_cursor(player_list_start_y + 1, title_x)
            + TerminalColors.BRIGHT_WHITE
            + title
            + TerminalColors.RESET
        )

        # Draw player count
        count_text = f" ONLINE: {player_count} "
        count_x = player_list_x + (player_list_width - len(count_text)) // 2
        count_color = (
            TerminalColors.BRIGHT_GREEN
            if player_count > 0
            else TerminalColors.BRIGHT_BLACK
        )
        sys.stdout.write(
            TerminalControl.move_cursor(player_list_start_y + 2, count_x)
            + count_color
            + count_text
            + TerminalColors.RESET
        )

        # Clear player list area
        for y in range(player_list_start_y + 3, player_list_end_y):
            sys.stdout.write(
                TerminalControl.move_cursor(y, player_list_x + 1)
                + " " * (player_list_width - 2)
            )

        # Draw player names
        if players:
            for i, player in enumerate(players):
                if (
                    player_list_start_y + 3 + i < player_list_end_y
                ):  # Make sure we don't overflow
                    # Truncate long player names
                    display_name = (
                        player[: player_list_width - 6]
                        if len(player) > player_list_width - 6
                        else player
                    )
                    player_text = f" 🟢 {display_name} "
                    if len(player) > player_list_width - 6:
                        player_text = player_text[:-3] + "… "

                    sys.stdout.write(
                        TerminalControl.move_cursor(
                            player_list_start_y + 3 + i, player_list_x + 1
                        )
                        + TerminalColors.BRIGHT_CYAN
                        + player_text
                        + TerminalColors.RESET
                    )
        else:
            # Show "No players" message
            no_players_text = " 🔴 NO PLAYERS "
            no_players_x = (
                player_list_x + (player_list_width - len(no_players_text)) // 2
            )
            sys.stdout.write(
                TerminalControl.move_cursor(player_list_start_y + 3, no_players_x)
                + TerminalColors.BRIGHT_BLACK
                + no_players_text
                + TerminalColors.RESET
            )

        self.clear_dirty("players")

    def scroll_log_up(self):
        """Scroll log up (show older lines) - faster scrolling"""
        with self.log_lock:
            total_lines = len(self.log_lines)
            log_height = self.max_y - 12  # Account for feedback frame and help lines

            if total_lines > log_height:
                # Scroll by 3 lines instead of 1 for faster navigation
                self.scroll_offset = min(
                    self.scroll_offset + 3, total_lines - log_height
                )
                self.mark_dirty("log")  # Mark log area for redraw

    def scroll_log_down(self):
        """Scroll log down (show newer lines) - faster scrolling"""
        # Scroll by 3 lines instead of 1 for faster navigation
        self.scroll_offset = max(0, self.scroll_offset - 3)
        self.mark_dirty("log")  # Mark log area for redraw

    def scroll_log_page_up(self):
        """Scroll log up by one page - show more content"""
        with self.log_lock:
            total_lines = len(self.log_lines)
            log_height = self.max_y - 12  # Account for feedback frame and help lines

            if total_lines > log_height:
                # Scroll by 75% of visible area for better page navigation
                page_size = max(1, int(log_height * 0.75))
                self.scroll_offset = min(
                    self.scroll_offset + page_size, total_lines - log_height
                )
                self.mark_dirty("log")  # Mark log area for redraw

    def scroll_log_page_down(self):
        """Scroll log down by one page - show more content"""
        log_height = self.max_y - 12  # Account for feedback frame and help lines
        # Scroll by 75% of visible area for better page navigation
        page_size = max(1, int(log_height * 0.75))
        self.scroll_offset = max(0, self.scroll_offset - page_size)
        self.mark_dirty("log")  # Mark log area for redraw

    def scroll_log_home(self):
        """Scroll to the beginning of the log (oldest entries)"""
        with self.log_lock:
            total_lines = len(self.log_lines)
            log_height = self.max_y - 12  # Account for feedback frame and help lines

            if total_lines > log_height:
                # Show the oldest entries (beginning of log)
                self.scroll_offset = total_lines - log_height
                self.mark_dirty("log")  # Mark log area for redraw

    def scroll_log_end(self):
        """Scroll to the end of the log (latest lines)"""
        # Show the newest entries (end of log)
        self.scroll_offset = 0
        self.mark_dirty("log")  # Mark log area for redraw

    def draw_help_area(self):
        """Draw the help/command area with dirty region tracking"""
        # Check if help area needs redrawing
        if not self.is_dirty("help"):
            return

        # Check if terminal size changed
        current_size = (self.max_y, self.max_x)
        if current_size == self._last_terminal_size and not self._needs_redraw:
            self.clear_dirty("help")
            return

        help_y = self.max_y - 3  # Adjusted for feedback frame

        # Calculate player list position
        player_list_x = self.max_x - 23  # Start 23 columns from right edge

        help_text = " ⚡ BUILT-IN: start|stop|restart|players|loginfo|quit "
        server_text = " 🎮 SERVER: /command [forwarded to server] "
        scroll_text = " 📜 SCROLL: ↑↓ PgUp/PgDn Home/End "

        # Clear help area (only up to player list)
        sys.stdout.write(
            TerminalControl.move_cursor(help_y, 1) + TerminalControl.clear_line()
        )
        sys.stdout.write(
            TerminalControl.move_cursor(help_y + 1, 1) + TerminalControl.clear_line()
        )
        sys.stdout.write(
            TerminalControl.move_cursor(help_y + 2, 1) + TerminalControl.clear_line()
        )

        # Draw help text (truncate if too long)
        max_length = player_list_x - 4
        if len(help_text) > max_length:
            help_text = help_text[: max_length - 3] + "..."
        if len(server_text) > max_length:
            server_text = server_text[: max_length - 3] + "..."
        if len(scroll_text) > max_length:
            scroll_text = scroll_text[: max_length - 3] + "..."

        sys.stdout.write(
            TerminalControl.move_cursor(help_y, 2)
            + TerminalColors.BRIGHT_MAGENTA
            + help_text
            + TerminalColors.RESET
        )
        sys.stdout.write(
            TerminalControl.move_cursor(help_y + 1, 2)
            + TerminalColors.BRIGHT_MAGENTA
            + server_text
            + TerminalColors.RESET
        )
        sys.stdout.write(
            TerminalControl.move_cursor(help_y + 2, 2)
            + TerminalColors.BRIGHT_CYAN
            + scroll_text
            + TerminalColors.RESET
        )

        self.clear_dirty("help")

    def draw_input_area(self):
        """Draw the command input area with dirty region tracking"""
        # Check if input area needs redrawing
        if not self.is_dirty("input"):
            return

        # Check if command buffer changed
        if self.command_buffer == self._last_command_buffer and not self._needs_redraw:
            self.clear_dirty("input")
            return  # No change, skip drawing

        self._last_command_buffer = self.command_buffer

        input_y = self.max_y - 1

        # Calculate player list position
        player_list_x = self.max_x - 23  # Start 23 columns from right edge

        # Clear input area (only up to player list)
        sys.stdout.write(
            TerminalControl.move_cursor(input_y, 1) + TerminalControl.clear_line()
        )

        # Draw input prompt and buffer using string formatting
        prompt = " 💻 COMMAND: "
        max_length = player_list_x - len(prompt) - 3
        display_buffer = (
            self.command_buffer[:max_length]
            if len(self.command_buffer) > max_length
            else self.command_buffer
        )

        input_line = prompt + display_buffer
        if len(self.command_buffer) > len(display_buffer):
            input_line += "…"

        sys.stdout.write(
            TerminalControl.move_cursor(input_y, 2)
            + TerminalColors.BRIGHT_GREEN
            + input_line
            + TerminalColors.RESET
        )

        # Position cursor
        cursor_x = len(prompt) + len(self.command_buffer)
        if cursor_x < player_list_x - 1:
            sys.stdout.write(TerminalControl.move_cursor(input_y, cursor_x + 2))

        self.clear_dirty("input")

    def handle_input(self) -> bool:
        """Handle user input with simplified, efficient processing"""
        try:
            # Handle incomplete escape sequences first
            if self.escape_buffer:
                return self.handle_incomplete_escape()

            # Non-blocking input check with consistent timeout and fallback
            input_ready = False
            try:
                input_ready = select.select([sys.stdin], [], [], self.input_timeout)[0]
            except OSError:
                # Fallback to longer timeout if system call fails
                input_ready = select.select(
                    [sys.stdin], [], [], self.input_timeout_fallback
                )[0]

            if input_ready:
                key = sys.stdin.read(1)

                if not key:
                    return True

                if key == "\x1b":  # ESC sequence
                    return self.handle_escape_sequence()

                elif key == "\r" or key == "\n":  # Enter
                    self.process_command()
                    self.command_buffer = ""
                    self.mark_dirty("input")
                    return True

                elif key == "\x7f" or key == "\x08":  # Backspace
                    if self.command_buffer:
                        self.command_buffer = self.command_buffer[:-1]
                        self.mark_dirty("input")
                    return True

                elif key == "\x03":  # Ctrl+C
                    return False

                elif key == "\x1a":  # Ctrl+Z
                    return False

                elif key.isprintable():
                    if len(self.command_buffer) < self.command_buffer_max:
                        self.command_buffer += key
                        self.mark_dirty("input")
                    return True
                else:
                    # Unknown key - consume and ignore
                    return True

            return True

        except KeyboardInterrupt:
            return False
        except Exception as e:
            # Log the exception but don't crash
            error_msg = f"Input error: {e}"
            print(f"\n{error_msg}", file=sys.stderr)
            self.add_command_log(error_msg)
            return True

    def handle_escape_sequence(self) -> bool:
        """Handle escape sequences with simplified, efficient processing"""
        try:
            # Read the next character with consistent timeout
            if not select.select([sys.stdin], [], [], self.input_timeout)[0]:
                self.escape_buffer = "\x1b"
                return True

            next_char = sys.stdin.read(1)
            self.escape_buffer = "\x1b" + next_char

            if next_char == "[":  # Control sequence
                return self.handle_control_sequence()
            elif next_char == "O":  # Function key sequence
                return self.handle_function_key()
            elif next_char == "M":  # Mouse event (disabled for SSH stability)
                self.escape_buffer = ""
                return True
            else:
                # Unknown escape sequence - consume and ignore
                self.escape_buffer = ""
                return True

        except Exception:
            self.escape_buffer = ""
            return True

    def handle_control_sequence(self) -> bool:
        """Handle control sequences with simplified lookup-based processing"""
        try:
            # Read the sequence with consistent timeout
            if not select.select([sys.stdin], [], [], self.input_timeout)[0]:
                return True

            seq = sys.stdin.read(1)
            self.escape_buffer += seq

            # Handle multi-character sequences (Page Up/Down)
            if seq in ["5", "6"]:
                if not select.select([sys.stdin], [], [], self.input_timeout)[0]:
                    return True

                next_char = sys.stdin.read(1)
                if next_char == "~":
                    self.escape_buffer += next_char
                    action = self.ESCAPE_SEQUENCES.get(self.escape_buffer, "ignore")
                    self.execute_action(action)
                    self.escape_buffer = ""
                    return True
                else:
                    # Invalid sequence
                    self.escape_buffer = ""
                    return True

            # Handle single-character sequences
            action = self.ESCAPE_SEQUENCES.get(self.escape_buffer, "ignore")
            self.execute_action(action)
            self.escape_buffer = ""
            return True

        except Exception:
            self.escape_buffer = ""
            return True

    def handle_incomplete_escape(self) -> bool:
        """Handle incomplete escape sequences with simplified processing"""
        try:
            # Try to read more data for the incomplete sequence
            if not select.select([sys.stdin], [], [], self.input_timeout)[0]:
                return True  # Still waiting for more data

            # Read one more character
            next_char = sys.stdin.read(1)
            self.escape_buffer += next_char

            # Process based on what we have so far
            if self.escape_buffer == "\x1b[":
                return self.handle_control_sequence()
            elif self.escape_buffer == "\x1bO":
                return self.handle_function_key()
            elif self.escape_buffer == "\x1bM":
                self.escape_buffer = ""
                return True  # Consume and ignore mouse events
            elif self.escape_buffer.startswith(
                "\x1b[5"
            ) or self.escape_buffer.startswith("\x1b[6"):
                # Continue reading for Page Up/Down
                if select.select([sys.stdin], [], [], self.input_timeout)[0]:
                    final_char = sys.stdin.read(1)
                    if final_char == "~":
                        self.escape_buffer += final_char
                        action = self.ESCAPE_SEQUENCES.get(self.escape_buffer, "ignore")
                        self.execute_action(action)
                        self.escape_buffer = ""
                        return True
                    else:
                        # Invalid sequence - consume and ignore
                        self.escape_buffer = ""
                        return True
                else:
                    return True  # Still waiting
            else:
                # Unknown sequence - consume and ignore
                self.escape_buffer = ""
                return True

        except Exception:
            self.escape_buffer = ""
            return True

    def handle_function_key(self) -> bool:
        """Handle function key sequences with simplified processing"""
        try:
            if not select.select([sys.stdin], [], [], self.input_timeout)[0]:
                return True

            seq = sys.stdin.read(1)
            self.escape_buffer += seq

            # Look up action in escape sequence table
            action = self.ESCAPE_SEQUENCES.get(self.escape_buffer, "ignore")
            self.execute_action(action)
            self.escape_buffer = ""
            return True

        except Exception:
            self.escape_buffer = ""
            return True

    def execute_action(self, action: str):
        """Execute the specified action from escape sequence lookup"""
        if action == "scroll_up":
            self.scroll_log_up()
        elif action == "scroll_down":
            self.scroll_log_down()
        elif action == "page_up":
            self.scroll_log_page_up()
        elif action == "page_down":
            self.scroll_log_page_down()
        elif action == "home":
            self.scroll_log_home()
        elif action == "end":
            self.scroll_log_end()
        elif action == "ignore":
            # Do nothing - just consume the input
            pass

    def handle_simple_mouse(self) -> bool:
        """Mouse handling disabled for SSH stability"""
        # Mouse events are completely disabled to prevent crashes
        return True

    def process_command(self):
        """Process the entered command"""
        if not self.command_buffer.strip():
            return

        cmd = self.command_buffer.strip().lower()

        if cmd in ["start", "s"]:
            if self.start_server():
                self.update_status()
                self.add_command_log(self.MESSAGES["server_started"])
            else:
                self.add_command_log(self.MESSAGES["server_start_failed"])

        elif cmd in ["stop", "st"]:
            if self.stop_server():
                self.update_status()
                self.add_command_log(self.MESSAGES["server_stopped"])
            else:
                self.add_command_log(self.MESSAGES["server_stop_failed"])

        elif cmd in ["restart", "r"]:
            # Non-blocking restart with background wait
            self.add_command_log("Restarting server...")
            # Use thread pool instead of creating new thread
            self.start_background_task(self.restart_sequence)

        # Help command removed - help information is always visible on screen

        elif cmd in ["players", "p"]:
            # Trigger immediate player count update before showing results
            self.add_command_log(self.MESSAGES["updating_players"])
            self.start_background_task(self.trigger_player_update)

            # Non-blocking: show current players immediately, update will happen in background
            players = self.get_online_players_list()
            if players:
                player_list = ", ".join(players)
                self.add_command_log(
                    self.MESSAGES["online_players"].format(player_list)
                )
            else:
                self.add_command_log(self.MESSAGES["no_players"])

        elif cmd in ["loginfo", "li"]:
            with self.log_lock:
                total_lines = len(self.log_lines)
                visible_lines = self.max_y - 12  # Account for UI elements
                current_position = (
                    total_lines - visible_lines - self.scroll_offset
                    if total_lines > visible_lines
                    else 0
                )

                # Add resource usage information
                memory_info = (
                    f"Memory: {self._memory_usage_mb:.1f}MB"
                    if self._memory_usage_mb > 0
                    else "Memory: N/A"
                )
                with self._command_lock:
                    command_log_size = len(self.command_log)

                # Calculate scroll position percentage
                if total_lines > visible_lines:
                    scroll_percent = int(
                        (self.scroll_offset / (total_lines - visible_lines)) * 100
                    )
                    scroll_info = f"Scroll: {scroll_percent}%"
                else:
                    scroll_info = "Scroll: 100%"

                # Add security information
                security_info = f"Security: {self.failed_commands} failed attempts, {len(self.security_events)} events"

                self.add_command_log(
                    f"Log: {total_lines} lines, showing {current_position + 1}-{min(current_position + visible_lines, total_lines)}, {scroll_info}, {memory_info}, Commands: {command_log_size}, {security_info}"
                )

        elif cmd in ["quit", "exit", "q"]:
            self.add_command_log(self.MESSAGES["quitting"])
            self.running = False

        elif cmd.startswith("/"):
            server_cmd = cmd[1:]
            # Additional validation for server commands
            if len(server_cmd) > 1000:
                self.log_security_event(
                    "COMMAND_TOO_LONG",
                    f"Server command too long: {len(server_cmd)} chars",
                )
                self.add_command_log(
                    "Server command too long - maximum 1000 characters"
                )
            elif self.send_command(server_cmd):
                self.add_command_log(self.MESSAGES["command_sent"].format(server_cmd))
            else:
                self.add_command_log(self.MESSAGES["command_failed"])
        else:
            # Unknown command
            self.add_command_log(self.MESSAGES["unknown_command"].format(cmd))

    def cleanup(self):
        """Enhanced cleanup on exit with proper resource management"""
        self.add_command_log("Starting cleanup sequence...")

        # Signal shutdown to all threads
        self._shutdown_event.set()

        # Stop log monitor with timeout
        self.add_command_log("Stopping log monitor...")
        self.stop_log_monitor()

        # Wait for all background tasks to complete with timeout
        self.add_command_log("Waiting for background tasks...")
        self.wait_for_background_tasks(timeout=5.0)

        # Clean up screen sessions
        self.cleanup_screen_sessions()

        # Final cleanup
        self.add_command_log(self.MESSAGES["cleanup_completed"])
        # Don't stop the server - let it keep running in background

    def cleanup_screen_sessions(self):
        """Clean up any orphaned screen sessions"""
        try:
            # Check if our screen session is still running
            result = subprocess.run(
                ["screen", "-list", self.screen_name],
                capture_output=True,
                text=True,
                timeout=2.0,
            )

            if result.returncode == 0 and self.screen_name in result.stdout:
                self.add_command_log(
                    f"Screen session '{self.screen_name}' is still running (intentional)"
                )
            else:
                self.add_command_log("No active screen sessions found")

        except subprocess.TimeoutExpired:
            self.add_command_log("Screen session check timed out")
        except Exception as e:
            self.add_command_log(f"Screen session cleanup error: {e}")

    def signal_handler(self, signum, frame):
        """Handle termination signals"""
        signal_name = {
            signal.SIGINT: "SIGINT",
            signal.SIGTERM: "SIGTERM",
            signal.SIGHUP: "SIGHUP",
        }.get(signum, f"Signal {signum}")

        self.add_command_log(f"Received {signal_name} - initiating graceful shutdown")
        self.running = False

    def emergency_shutdown(self):
        """Emergency shutdown for critical failures"""
        self.add_command_log("EMERGENCY SHUTDOWN - Critical failure detected")

        # Force stop all threads
        self._shutdown_event.set()

        # Kill any remaining background tasks
        for thread in self._background_tasks:
            if thread.is_alive():
                self.add_command_log(
                    f"Force terminating background task: {thread.name}"
                )

        # Clear background tasks list
        self._background_tasks.clear()

        self.add_command_log("Emergency shutdown completed")

    def run(self):
        """Main application loop"""
        # Enhanced signal handling for graceful shutdown
        signal.signal(signal.SIGINT, self.signal_handler)  # Ctrl+C
        signal.signal(signal.SIGTERM, self.signal_handler)  # Termination request
        signal.signal(signal.SIGHUP, self.signal_handler)  # Hangup (SSH disconnect)

        # Ignore SIGPIPE to prevent crashes on broken pipes
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)

        try:
            self.check_dependencies()

            # Validate configuration before starting
            if not self.validate_configuration():
                self.add_command_log("Configuration validation failed")
                return

            # Validate paths before starting
            if not self.validate_paths():
                self.add_command_log("Path validation failed - check configuration")
                return

            self.setup_terminal()

            # Ensure terminal is properly initialized
            if self.max_y == 0 or self.max_x == 0:
                self.max_y, self.max_x = 24, 80  # Fallback terminal size

            self.update_status()
            self.add_command_log("Terminal setup completed")
            self.start_log_monitor()
            self.add_command_log("Log monitoring started")

            while self.running:
                # Frame rate limiting
                current_time = time.time()
                elapsed = current_time - self.last_frame_time

                if elapsed < self.frame_time:
                    # Sleep to maintain target FPS
                    time.sleep(self.frame_time - elapsed)
                    continue

                self.last_frame_time = current_time

                # Check for terminal resize
                self.check_terminal_resize()

                # Update status periodically (cached, so fast)
                self.update_status()

                # Periodic memory cleanup
                self.cleanup_memory()

                # Resource monitoring
                self.check_resources()

                # Security status check
                self.check_security_status()

                # Periodic input buffer cleanup (every 30 seconds)
                if current_time % 30 < 0.016:  # Every 30 seconds
                    if len(self.escape_buffer) > 5:  # More aggressive cleanup
                        self.escape_buffer = ""

                # Draw UI only when needed using dirty region tracking
                try:
                    self.draw_header()
                    self.draw_borders()
                    self.draw_log_area()
                    self.draw_player_list()
                    self.draw_feedback_frame()
                    self.draw_help_area()
                    self.draw_input_area()

                    # Ensure at least one complete draw on startup
                    if self._needs_redraw:
                        self._needs_redraw = False
                except (OSError, IOError):
                    # Terminal I/O error in UI drawing
                    sys.stdout.write(
                        TerminalControl.move_cursor(1, 1)
                        + "VintageStory Server Manager - Terminal I/O Error"
                    )
                    self._needs_redraw = False
                except Exception:
                    # Unexpected error in UI drawing
                    sys.stdout.write(
                        TerminalControl.move_cursor(1, 1)
                        + "VintageStory Server Manager - Error in UI drawing"
                    )
                    self._needs_redraw = False

                sys.stdout.flush()

                # Handle input
                if not self.handle_input():
                    break

                # Reset redraw flag
                self._needs_redraw = False

        except (OSError, IOError) as e:
            print(f"Terminal I/O Error: {e}")
            import traceback

            traceback.print_exc()
            # Use emergency shutdown for critical errors
            self.emergency_shutdown()
        except Exception as e:
            print(f"Unexpected Error: {e}")
            import traceback

            traceback.print_exc()
            # Use emergency shutdown for critical errors
            self.emergency_shutdown()

        finally:
            # Ensure cleanup happens even on emergency shutdown
            try:
                self.cleanup()
            except Exception as cleanup_error:
                print(f"Cleanup error: {cleanup_error}", file=sys.stderr)

            # Always restore terminal
            try:
                self.restore_terminal()
            except (OSError, IOError) as restore_error:
                print(f"Terminal restore I/O error: {restore_error}", file=sys.stderr)
            except Exception as restore_error:
                print(
                    f"Terminal restore unexpected error: {restore_error}",
                    file=sys.stderr,
                )

    def invalidate_caches(self):
        """Invalidate all caches to force fresh data"""
        self._process_info_cache = None
        self._process_info_cache_time = 0
        self._pid_cache_time = 0
        self.pid_update_needed = True
        self._needs_redraw = True

    def force_redraw(self):
        """Force a complete redraw of the UI"""
        self._needs_redraw = True
        self._dirty_regions = {
            "header",
            "borders",
            "log",
            "players",
            "feedback",
            "help",
            "input",
        }
        # Clear cached drawing flags
        if hasattr(self, "_header_drawn"):
            delattr(self, "_header_drawn")
        if hasattr(self, "_borders_drawn"):
            delattr(self, "_borders_drawn")
        if hasattr(self, "_help_drawn"):
            delattr(self, "_help_drawn")
        if hasattr(self, "_last_log_hash"):
            delattr(self, "_last_log_hash")
        if hasattr(self, "_last_feedback_hash"):
            delattr(self, "_last_feedback_hash")

    def mark_dirty(self, region: str):
        """Mark a UI region as needing redraw"""
        self._dirty_regions.add(region)

    def is_dirty(self, region: str) -> bool:
        """Check if a UI region needs redrawing"""
        return region in self._dirty_regions or self._needs_redraw

    def clear_dirty(self, region: str):
        """Mark a UI region as clean (no longer needs redrawing)"""
        self._dirty_regions.discard(region)

    def start_background_task(self, task_func, *args, **kwargs):
        """Start a background task with thread pool management"""
        # Clean up completed threads
        self._background_tasks = [t for t in self._background_tasks if t.is_alive()]

        # Check if we can start a new task
        if len(self._background_tasks) >= self._max_background_tasks:
            # Too many background tasks, skip this one
            return None

        # Create and start the thread
        thread = threading.Thread(
            target=task_func, args=args, kwargs=kwargs, daemon=True
        )
        thread.start()
        self._background_tasks.append(thread)
        return thread

    def wait_for_background_tasks(self, timeout=5.0):
        """Wait for background tasks to complete with timeout"""
        if not self._background_tasks:
            return

        self.add_command_log(
            f"Waiting for {len(self._background_tasks)} background tasks..."
        )

        start_time = time.time()
        for thread in self._background_tasks:
            if thread.is_alive():
                remaining_timeout = max(0, timeout - (time.time() - start_time))
                if remaining_timeout <= 0:
                    self.add_command_log("Background task timeout - forcing shutdown")
                    break
                thread.join(timeout=remaining_timeout)

        # Clean up any remaining tasks
        self._background_tasks = [t for t in self._background_tasks if not t.is_alive()]
        if self._background_tasks:
            self.add_command_log(
                f"Warning: {len(self._background_tasks)} background tasks did not complete"
            )
        else:
            self.add_command_log("All background tasks completed successfully")

    def safe_execute(self, func, *args, **kwargs):
        """Safely execute a function with error handling"""
        try:
            return func(*args, **kwargs)
        except Exception as e:
            self.log_error(f"Error in {func.__name__}: {e}")
            return None

    def log_error(self, message: str, exception: Exception = None):
        """Centralized error logging"""
        timestamp = time.strftime("%H:%M:%S")
        error_msg = f"[{timestamp}] ERROR: {message}"

        if exception:
            error_msg += f" - {type(exception).__name__}: {str(exception)}"

        # Log to command log
        self.add_command_log(error_msg)

        # Also print to stderr for debugging
        print(error_msg, file=sys.stderr)

    def validate_paths(self):
        """Validate that all required paths exist and are accessible"""
        paths_to_check = [
            (self.vs_path, "Server directory"),
            (self.data_path, "Data directory"),
            (os.path.join(self.vs_path, self.service), "Service file"),
        ]

        for path, description in paths_to_check:
            if not os.path.exists(path):
                self.log_error(f"{description} not found: {path}")
                return False

        return True

    def validate_input(self, input_str: str, input_type: str) -> bool:
        """Validate input against security patterns"""
        if not input_str:
            return False

        pattern = self.SECURITY_PATTERNS.get(input_type)
        if not pattern:
            return False

        return bool(re.match(pattern, input_str))

    def sanitize_command(self, command: str) -> str:
        """Sanitize server command for safe execution"""
        if not command:
            return ""

        # Check for rate limiting
        if self.failed_commands > 10:
            self.log_security_event(
                "RATE_LIMIT", f"Too many failed commands: {self.failed_commands}"
            )
            return ""

        # Check for dangerous patterns
        command_lower = command.lower()
        for pattern in self.DANGEROUS_PATTERNS:
            if re.search(pattern, command_lower):
                self.log_security_event(
                    "DANGEROUS_PATTERN", f"Blocked dangerous pattern: {pattern}"
                )
                return ""

        # Remove any dangerous characters
        dangerous_chars = ["`", "$", "&", "|", ";", "<", ">", "(", ")", "{", "}"]
        for char in dangerous_chars:
            command = command.replace(char, "")

        # Limit command length
        if len(command) > 1000:
            command = command[:1000]

        return command.strip()

    def check_security_status(self):
        """Check security status and reset counters if needed"""
        current_time = time.time()

        # Reset failed commands counter every 5 minutes
        if current_time - self.last_security_check > 300:  # 5 minutes
            if self.failed_commands > 0:
                self.log_security_event(
                    "SECURITY_RESET",
                    f"Reset failed commands counter: {self.failed_commands}",
                )
            self.failed_commands = 0
            self.last_security_check = current_time

    def log_security_event(self, event_type: str, details: str):
        """Log security-related events with tracking"""
        timestamp = time.strftime("%H:%M:%S")
        security_msg = f"[SECURITY] {event_type}: {details}"

        # Track security events
        self.security_events.append(
            {"timestamp": timestamp, "type": event_type, "details": details}
        )

        # Increment failed commands counter for certain events
        if event_type in ["INVALID_COMMAND", "COMMAND_TOO_LONG"]:
            self.failed_commands += 1

        self.add_command_log(security_msg)
        print(f"{timestamp} {security_msg}", file=sys.stderr)

    def validate_configuration(self):
        """Validate configuration constants"""
        # Check required configuration keys
        required_config_keys = [
            "username",
            "vs_path",
            "data_path",
            "screen_name",
            "service",
        ]
        for key in required_config_keys:
            if key not in self.CONFIG:
                self.log_error(f"Missing required configuration key: {key}")
                return False

        # Check required performance keys
        required_perf_keys = [
            "target_fps",
            "process_cache_interval",
            "log_buffer_max_size",
        ]
        for key in required_perf_keys:
            if key not in self.PERFORMANCE:
                self.log_error(f"Missing required performance key: {key}")
                return False

        # Check required message keys
        required_msg_keys = ["server_started", "server_start_failed", "quitting"]
        for key in required_msg_keys:
            if key not in self.MESSAGES:
                self.log_error(f"Missing required message key: {key}")
                return False

        return True

    def cleanup_memory(self):
        """Periodic memory cleanup to prevent memory leaks"""
        current_time = time.time()

        if current_time - self._last_memory_cleanup < self._memory_cleanup_interval:
            return

        self._last_memory_cleanup = current_time

        # Force garbage collection
        import gc

        gc.collect()

        # Trim log lines if they exceed reasonable limits
        with self.log_lock:
            if (
                len(self.log_lines) > self.PERFORMANCE["log_buffer_max_size"] * 0.8
            ):  # Keep under 80% of max
                # Remove oldest lines, keeping recent ones
                target_size = int(self.PERFORMANCE["log_buffer_max_size"] * 0.8)
                excess = len(self.log_lines) - target_size
                for _ in range(excess):
                    self.log_lines.popleft()

        # Clear old command log entries if too many
        with self._command_lock:
            if (
                len(self.command_log) > self.PERFORMANCE["command_log_max_size"] * 0.8
            ):  # Keep under 80% of max
                target_size = int(self.PERFORMANCE["command_log_max_size"] * 0.8)
                excess = len(self.command_log) - target_size
                for _ in range(excess):
                    self.command_log.popleft()

        # Clear escape buffer if it's been stuck
        if len(self.escape_buffer) > 10:
            self.escape_buffer = ""

        # Reset any stuck flags
        if hasattr(self, "_terminal_resized"):
            delattr(self, "_terminal_resized")

    def check_resources(self):
        """Monitor resource usage and log warnings if needed"""
        current_time = time.time()

        if current_time - self._last_resource_check < self._resource_check_interval:
            return

        self._last_resource_check = current_time

        # Check memory usage
        try:
            import psutil

            process = psutil.Process()
            memory_info = process.memory_info()
            self._memory_usage_mb = memory_info.rss / 1024 / 1024  # Convert to MB

            # Log warning if memory usage is high
            if self._memory_usage_mb > self.PERFORMANCE["memory_warning_threshold"]:
                self.add_command_log(
                    self.MESSAGES["high_memory_usage"].format(self._memory_usage_mb)
                )
        except ImportError:
            # psutil not available, skip memory monitoring
            pass
        except Exception:
            # Ignore memory monitoring errors
            pass

        # Check log buffer size
        with self.log_lock:
            self._log_lines_count = len(self.log_lines)

        # Log warning if log buffer is getting large
        if self._log_lines_count > self.PERFORMANCE["log_buffer_warning_threshold"]:
            self.add_command_log(
                self.MESSAGES["large_log_buffer"].format(self._log_lines_count)
            )

        # Check command log size
        with self._command_lock:
            if (
                len(self.command_log)
                > self.PERFORMANCE["command_log_warning_threshold"]
            ):
                self.add_command_log(
                    self.MESSAGES["large_command_log"].format(len(self.command_log))
                )

    def strip_timestamp(self, line: str) -> str:
        """Strip timestamp prefix from log lines"""
        # Pattern: "1.8.2025 20:22:44 " or similar date/time formats

        # Match common timestamp patterns
        timestamp_patterns = [
            r"^\d{1,2}\.\d{1,2}\.\d{4}\s+\d{1,2}:\d{2}:\d{2}\s+",  # 1.8.2025 20:22:44
            r"^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+",  # 2025-01-08 20:22:44
            r"^\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}:\d{2}\s+",  # 01/08/2025 20:22:44
        ]

        for pattern in timestamp_patterns:
            if re.match(pattern, line):
                # Remove the timestamp and return the rest
                return re.sub(pattern, "", line)

        return line


def main():
    """Main entry point"""
    print("🚀 VintageStory Server Manager")
    print("Starting dependency check...")

    manager = VintageStoryServerManager()
    manager.run()


if __name__ == "__main__":
    main()
