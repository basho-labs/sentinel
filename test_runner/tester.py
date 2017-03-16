import pytest
import paho.mqtt.publish as publish
import paho.mqtt.client as mqtt

message_sent = False
message_recieved = False

@pytest.fixture
def mqtt_client_factory(request):
    class ClientFactory(object):
        def new(self, client_id, on_message, host, sub_topic):
            mqtt_client = mqtt.Client(client_id)
            mqtt_client.on_message = on_message
            mqtt_client.connect(host=host, port=1883, keepalive=60)
            mqtt_client.subscribe(sub_topic, 0)
            mqtt_client.loop_start()
            request.addfinalizer(mqtt_client.loop_stop)
            return mqtt_client
    return ClientFactory()

def on_message_source(_mqttc, obj, msg):
    global message_sent
    print('Source message received')
    message_sent = True
    return

def on_message_sink(_mqttc, obj, msg):
    global message_recieved
    print('Sink message received')
    message_recieved = True
    return

@pytest.mark.parametrize("source_hostname", ["sentinel_device_a0_1", "sentinel_device_a1_1", \
                                             "sentinel_device_a2_1", "sentinel_device_a3_1", \
                                             "sentinel_gateway_a_1"])
@pytest.mark.parametrize("sink_hostname", ["sentinel_device_a0_1", "sentinel_device_b0_1", \
                                           "sentinel_device_a1_1", "sentinel_device_b1_1", \
                                           "sentinel_device_a2_1", "sentinel_device_b2_1", \
                                           "sentinel_device_a3_1", "sentinel_device_b3_1", \
                                           "sentinel_gateway_a_1", "sentinel_gateway_b_1"])
@pytest.mark.timeout(5)
def test_send_message(mqtt_client_factory, source_hostname, sink_hostname):
    print('Testing-- SOURCE: '+source_hostname+' SINK: '+sink_hostname)
    global message_sent
    global message_recieved
    message_sent = False
    message_recieved = False

    sink_client_id = "sink_client"
    sink_sub_topic = 'send/message/'+sink_hostname
    sink_client = mqtt_client_factory.new(sink_client_id, on_message_sink, sink_hostname, sink_sub_topic)

    source_client_id = "source_client"
    source_sub_topic = 'send/message/'+sink_hostname
    source_client = mqtt_client_factory.new(source_client_id, on_message_source, source_hostname, source_sub_topic)

    publish.single('message/'+sink_hostname, payload= "this is a test message", hostname=source_hostname)
    print('waiting for message to be sent')
    while message_sent != True:
        pass
    assert  message_sent == True
    print('waiting for message to be received')
    while message_recieved != True:
        pass
    assert message_recieved == True
