package com.diegonmarcos.comms.updater

/**
 * Process-wide observable state for the fleet updater. The check/download/install
 * pipeline writes states here as it advances; the About screen observes via
 * [setListener]. `target` is the fleet label currently being processed (hub /
 * mail / chat / matrix). Plain singleton + callback — no Coroutines/LiveData dep.
 */
object UpdateProgress {

    sealed class State {
        object Idle : State()
        data class Checking(val target: String) : State()
        data class Downloading(val target: String, val percent: Int, val bytes: Long, val total: Long) : State()
        data class Installing(val target: String) : State()
        data class UpToDate(val checked: Int) : State()
        data class Failed(val target: String, val message: String) : State()
    }

    @Volatile var state: State = State.Idle
        private set

    private var listener: ((State) -> Unit)? = null

    fun setListener(l: ((State) -> Unit)?) {
        listener = l
        if (l != null) l(state)   // replay current state for a late subscriber
    }

    fun update(next: State) {
        state = next
        listener?.invoke(next)
    }

    fun reset() = update(State.Idle)
}
