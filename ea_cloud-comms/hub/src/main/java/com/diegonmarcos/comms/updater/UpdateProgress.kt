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
        /** [step]/[steps] locate the app inside an all-or-nothing flow run
         *  (SetupFlow / UpdateWorker); 0/0 = standalone action. The overlay
         *  renders a per-app bar AND a total bar from them. */
        data class Checking(val target: String, val step: Int = 0, val steps: Int = 0) : State()
        data class Downloading(
            val target: String, val percent: Int, val bytes: Long, val total: Long,
            val step: Int = 0, val steps: Int = 0,
        ) : State()
        data class Installing(val target: String, val step: Int = 0, val steps: Int = 0) : State()
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
