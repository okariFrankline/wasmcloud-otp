defmodule HostCore.Providers.ProviderModule do
  @moduledoc false
  use GenServer, restart: :transient
  require Logger
  alias HostCore.CloudEvent

  @thirty_seconds 30_000

  defmodule State do
    @moduledoc false

    defstruct [
      :os_port,
      :os_pid,
      :link_name,
      :contract_id,
      :public_key,
      :lattice_prefix,
      :instance_id,
      :annotations,
      :executable_path,
      :ociref,
      :healthy
    ]
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

  def instance_id(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_instance_id)
    else
      "n/a"
    end
  end

  def annotations(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_annotations)
    else
      %{}
    end
  end

  def ociref(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_ociref)
    else
      "n/a"
    end
  end

  def path(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :get_path)
    else
      "n/a"
    end
  end

  def halt(pid) do
    if Process.alive?(pid), do: GenServer.call(pid, :halt_cleanup)
  end

  @impl true
  def init({:executable, path, claims, link_name, contract_id, oci, config_json, annotations}) do
    Logger.info("Starting executable capability provider from '#{path}'",
      provider_id: claims.public_key,
      link_name: link_name,
      contract_id: contract_id
    )

    instance_id = UUID.uuid4()
    # In case we want to know the contract ID of this provider, we can look it up as the
    # bound value in the registry.

    # Store the provider pid
    Registry.register(Registry.ProviderRegistry, {claims.public_key, link_name}, contract_id)
    # Store the provider triple in an ETS table
    HostCore.Providers.register_provider(claims.public_key, link_name, contract_id)

    host_info =
      HostCore.Host.generate_hostinfo_for(
        claims.public_key,
        link_name,
        instance_id,
        config_json
      )
      |> Base.encode64()
      |> to_charlist()

    port = Port.open({:spawn, "#{path}"}, [:binary, {:env, extract_env_vars()}])
    Port.monitor(port)
    Port.command(port, "#{host_info}\n")

    {:os_pid, pid} = Port.info(port, :os_pid)

    # Worth pointing out here that this process doesn't need to subscribe to
    # the provider's NATS topic. The provider subscribes to that directly
    # when it starts.

    HostCore.Claims.Manager.put_claims(claims)
    publish_provider_started(claims, link_name, contract_id, instance_id, oci, annotations)

    if oci != nil && oci != "" do
      publish_provider_oci_map(claims.public_key, link_name, oci)
    end

    Process.send_after(self(), :do_health, 5_000)
    :timer.send_interval(@thirty_seconds, self(), :do_health)

    {:ok,
     %State{
       os_port: port,
       os_pid: pid,
       public_key: claims.public_key,
       link_name: link_name,
       contract_id: contract_id,
       instance_id: instance_id,
       lattice_prefix: HostCore.Host.lattice_prefix(),
       executable_path: path,
       annotations: annotations,
       # until we prove otherwise
       healthy: false,
       ociref: oci
     }}
  end

  @propagated_env_vars ["OTEL_TRACES_EXPORTER", "OTEL_EXPORTER_OTLP_ENDPOINT"]

  defp extract_env_vars() do
    @propagated_env_vars
    |> Enum.map(fn e -> {e |> to_charlist(), System.get_env(e) |> to_charlist()} end)
    |> Enum.filter(fn {_k, v} -> length(v) > 0 end)
    |> Enum.into([])
  end

  @impl true
  def handle_call(:halt_cleanup, _from, state) do
    # Elixir cleans up ports, but it doesn't always clean up the OS process it created
    # for that port. TODO - find a clean, reliable way of killing these processes.
    if state.os_pid != nil do
      System.cmd("kill", ["-9", "#{state.os_pid}"])
    end

    publish_provider_stopped(
      state.public_key,
      state.link_name,
      state.instance_id,
      state.contract_id,
      "normal"
    )

    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call(:identity_tuple, _from, state) do
    {:reply, {state.public_key, state.link_name}, state}
  end

  @impl true
  def handle_call(:get_instance_id, _from, state) do
    {:reply, state.instance_id, state}
  end

  @impl true
  def handle_call(:get_annotations, _from, state) do
    {:reply, state.annotations, state}
  end

  @impl true
  def handle_call(:get_path, _from, state) do
    {:reply, state.executable_path, state}
  end

  @impl true
  def handle_call(:get_ociref, _from, state) do
    {:reply, state.ociref, state}
  end

  @impl true
  def handle_info({_ref, {:data, logline}}, state) do
    Logger.info("[#{state.public_key}]: #{logline}",
      provider_id: state.public_key,
      link_name: state.link_name,
      contract_id: state.contract_id
    )

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :port, _port, :normal}, state) do
    Logger.debug("Received DOWN message from port (provider stopped normally)",
      provider_id: state.public_key,
      link_name: state.link_name,
      contract_id: state.contract_id
    )

    publish_provider_stopped(
      state.public_key,
      state.link_name,
      state.instance_id,
      state.contract_id,
      "normal"
    )

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :port, _port, reason}, state) do
    Logger.error("Received DOWN message from port (provider stopped) - #{reason}",
      provider_id: state.public_key,
      link_name: state.link_name,
      contract_id: state.contract_id
    )

    publish_provider_stopped(
      state.public_key,
      state.link_name,
      state.instance_id,
      state.contract_id,
      "#{reason}"
    )

    {:stop, reason, state}
  end

  @impl true
  def handle_info(:do_health, state) do
    topic = "wasmbus.rpc.#{state.lattice_prefix}.#{state.public_key}.#{state.link_name}.health"
    payload = %{placeholder: true} |> Msgpax.pack!() |> IO.iodata_to_binary()

    res =
      try do
        HostCore.Nats.safe_req(:lattice_nats, topic, payload,
          receive_timeout: HostCore.Host.rpc_timeout()
        )
      rescue
        _e -> {:error, "Received no response on health check topic from provider"}
      end

    # Only publish health check pass/fail when state changes
    state =
      case res do
        {:ok, _body} when not state.healthy ->
          publish_health_passed(state)
          %State{state | healthy: true}

        {:ok, _body} ->
          state

        {:error, _} ->
          if state.healthy do
            publish_health_failed(state)
            %State{state | healthy: false}
          else
            state
          end
      end

    {:noreply, state}
  end

  def handle_info({_ref, msg}, state) do
    Logger.debug(msg)

    {:noreply, state}
  end

  defp publish_provider_oci_map(public_key, _link_name, oci) do
    HostCore.Refmaps.Manager.put_refmap(oci, public_key)
  end

  defp publish_health_passed(state) do
    prefix = HostCore.Host.lattice_prefix()

    msg =
      %{
        public_key: state.public_key,
        link_name: state.link_name
      }
      |> CloudEvent.new("health_check_passed")

    topic = "wasmbus.evt.#{prefix}"

    HostCore.Nats.safe_pub(:control_nats, topic, msg)
  end

  defp publish_health_failed(state) do
    prefix = HostCore.Host.lattice_prefix()

    msg =
      %{
        public_key: state.public_key,
        link_name: state.link_name
      }
      |> CloudEvent.new("health_check_failed")

    topic = "wasmbus.evt.#{prefix}"

    HostCore.Nats.safe_pub(:control_nats, topic, msg)
  end

  @spec publish_provider_stopped(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok
  def publish_provider_stopped(public_key, link_name, instance_id, contract_id, reason) do
    prefix = HostCore.Host.lattice_prefix()

    msg =
      %{
        public_key: public_key,
        link_name: link_name,
        contract_id: contract_id,
        instance_id: instance_id,
        reason: reason
      }
      |> CloudEvent.new("provider_stopped")

    topic = "wasmbus.evt.#{prefix}"

    HostCore.Nats.safe_pub(:control_nats, topic, msg)
  end

  defp publish_provider_started(
         claims,
         link_name,
         contract_id,
         instance_id,
         image_ref,
         annotations
       ) do
    prefix = HostCore.Host.lattice_prefix()

    msg =
      %{
        public_key: claims.public_key,
        image_ref: image_ref,
        link_name: link_name,
        contract_id: contract_id,
        instance_id: instance_id,
        annotations: annotations,
        claims: %{
          issuer: claims.issuer,
          tags: claims.tags,
          name: claims.name,
          version: claims.version,
          not_before_human: claims.not_before_human,
          expires_human: claims.expires_human
        }
      }
      |> CloudEvent.new("provider_started")

    topic = "wasmbus.evt.#{prefix}"

    HostCore.Nats.safe_pub(:control_nats, topic, msg)
  end
end
