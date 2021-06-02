defmodule HostCore.Providers.ProviderModule do
    use GenServer, restart: :temporary
    require Logger

    defmodule State do
        defstruct [:os_port, :os_pid, :link_name, :contract_id, :public_key]
    end

    @doc """
    Starts the provider module assuming it is an executable file
    """
    def start_link(opts) do
        GenServer.start_link(__MODULE__, opts)
    end

    def identity_tuple(pid) do
        GenServer.call(pid, :identity_tuple)
    end

    def cleanup(pid) do
        GenServer.cast(pid, :cleanup)
    end


    @impl true
    def init({:executable, path, public_key, link_name, contract_id}) do
        Logger.info("Starting executable capability provider at  '#{path}'")
        port = Port.open({:spawn, "#{path}"}, [:binary])
        {:os_pid, pid} = Port.info(port, :os_pid)

        # Worth pointing out here that this process doesn't need to subscribe to
        # the provider's NATS topic. The provider now subscribes to that directly
        # when it starts.
        publish_provider_started(public_key, link_name, contract_id)

        {:ok, %State{ os_port: port,
                       os_pid: pid,
                   public_key: public_key,
                    link_name: link_name,
                  contract_id: contract_id }}
    end

    @impl true
    def handle_call(:cleanup, _from, state) do
        if state.os_pid != nil do
            System.cmd("kill", ["-9", "#{state.os_pid}"])
        end
        {:noreply, state}
    end

    @impl true
    def handle_call(:identity_tuple, _from, state) do
        {:reply, {state.public_key, state.link_name}, state}
    end

    @impl true
    def handle_call(:get_pk, _from, state) do
        {:reply, state.public_key, state}
    end

    @impl true
    def handle_call(:get_link_name, _from, state) do
        {:reply, state.link_name, state}
    end

    @impl true
    def handle_info({_ref, {:data, logline}}, state) do
        Logger.info("Provider: #{logline}")

        {:noreply, state}
    end

    def handle_info({_ref, msg}, state) do
        Logger.info(msg)

        {:noreply, state}
    end

    def publish_provider_stopped(public_key, link_name) do
        prefix = HostCore.Host.lattice_prefix()
        stamp = DateTime.utc_now() |> DateTime.to_iso8601

        host = HostCore.Host.host_key()
        msg = %{
            specversion: "1.0",
            time: stamp,
            type: "com.wasmcloud.lattice.provider_stopped",
            source: "#{host}",
            datacontenttype: "application/json",
            id: UUID.uuid4(),
            data: %{
                public_key: public_key,
                link_name: link_name
            }
        }
        |> Cloudevents.from_map!()
        |> Cloudevents.to_json()
        topic = "wasmbus.ctl.#{prefix}.events"

        Gnat.pub(:control_nats, topic, msg)
    end

    defp publish_provider_started(pk, link_name, contract_id) do
        prefix = HostCore.Host.lattice_prefix()
        stamp = DateTime.utc_now() |> DateTime.to_iso8601

        host = HostCore.Host.host_key()
        msg = %{
            specversion: "1.0",
            time: stamp,
            type: "com.wasmcloud.lattice.provider_started",
            source: "#{host}",
            datacontenttype: "application/json",
            id: UUID.uuid4(),
            data: %{
                public_key: pk,
                link_name: link_name,
                contract_id: contract_id
            }
        }
        |> Cloudevents.from_map!()
        |> Cloudevents.to_json()
        topic = "wasmbus.ctl.#{prefix}.events"

        Gnat.pub(:control_nats, topic, msg)
    end

end