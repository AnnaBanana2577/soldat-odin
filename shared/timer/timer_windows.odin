// Package timer asks the system for a fine sleep. Windows sleeps in steps of its timer
// period, 15.6 ms unless asked for finer: a whole tick, which a loop that sleeps
// between ticks (the server, the headless client) would run late by.
package timer

import win "core:sys/windows"

fine_sleep_begin :: proc() { win.timeBeginPeriod(1) }
fine_sleep_end   :: proc() { win.timeEndPeriod(1) }
