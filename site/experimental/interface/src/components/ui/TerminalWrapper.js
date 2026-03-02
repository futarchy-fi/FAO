'use client';

export function TerminalWrapper({ children }) {
    return (
        <div className="fixed inset-0 bg-white dark:bg-black flex items-center justify-center p-0 sm:p-2 md:p-4 z-[1000]">
            {/* The Outer Monitor Case - Silver/Dark Metallic */}
            <div className="relative w-full h-full max-w-7xl max-h-[100vh] border-[8px] sm:border-[12px] md:border-[30px] border-black/80 dark:border-[#1d1d1d] rounded-none sm:rounded-[24px] md:rounded-[60px] shadow-[0_0_150px_rgba(0,0,0,0.05)] dark:shadow-[0_0_150px_rgba(255,255,255,0.05)] overflow-hidden flex flex-col bg-white dark:bg-black">

                {/* The CRT Screen Content */}
                <div className="relative flex-1 bg-white dark:bg-black overflow-hidden flex flex-col">

                    {/* Visual Overlays */}
                    <div className="absolute inset-0 z-0 opacity-20 pointer-events-none bg-[radial-gradient(circle_at_50%_50%,rgba(0,0,0,0.05),transparent)] dark:bg-[radial-gradient(circle_at_50%_50%,rgba(255,255,255,0.05),transparent)]" />
                    <div className="scanline-move" />
                    <div className="absolute inset-0 pointer-events-none z-[101] crt-flicker opacity-30" />

                    {/* Content Layer */}
                    <div className="relative z-10 flex-1 overflow-auto p-4 sm:p-8 md:p-12 scrollbar-hide">
                        {children}
                    </div>
                </div>

                {/* Monitor Bezel Bottom Detail */}
                <div className="h-10 sm:h-12 md:h-14 bg-[#1d1d1d] flex items-center justify-between px-4 sm:px-10 md:px-16 border-t border-white/5">
                    <div className="flex gap-4 sm:gap-6 items-center">
                        <div className="w-4 h-4 rounded-full bg-white/10 shadow-inner border border-white/5" />
                        <div className="w-8 h-1 bg-white/5 rounded-full" />
                    </div>
                    <div className="flex items-center gap-3 sm:gap-4">
                        <div className="text-[8px] sm:text-[9px] font-pixel text-white/20 tracking-[0.35em] sm:tracking-[0.5em] uppercase">
                            FAO.OS // MONOCHROME_STATION_4
                        </div>
                        <div className="w-1.5 h-1.5 rounded-full bg-white animate-pulse shadow-[0_0_8px_white]" />
                    </div>
                </div>
            </div>
        </div>
    );
}
