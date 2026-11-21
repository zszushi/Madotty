# Windows x64 console host

Madotty ships the x64 OpenConsole host built from Microsoft's Windows Terminal source at commit `dc8ae365847d41f62d1ebca93815bb00959bc12f` (v1.25.2733.0). The matching ConPTY DLL comes from the existing Microsoft.Windows.Console.ConPTY NuGet dependency. Other architectures use the corresponding Microsoft binaries.

The patch changes the search for attribute runs, ASCII column offset generation, CSI number parsing, and the calculation of the visible viewport. The host processes each full console write before forwarding it. Its Console Handoff class retains the upstream identifier.

For source builds, check out the upstream revision with its submodules, apply `openconsole.patch` with `git apply --ignore-space-change`, restore the upstream dependencies, and build the `Conhost\Host_EXE` target of `OpenConsole.slnx` in Release x64 with `WindowsTerminalBranding=Release`. The binary supplied here used the MSVC 14.51.36257 compiler and linker and a local instrumented profile. Training included Git history, build logs, terminal editing, Unicode text, color dashboards and image previews. Output performance varies with the toolchain and training profile.

The upstream license and third-party acknowledgments accompany the installed binary under `share/licenses/conpty`.
