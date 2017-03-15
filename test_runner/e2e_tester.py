import paho.mqtt.publish as publish
import paho.mqtt.client as mqtt
import sys
import time

msg_source = sys.argv[1]
msg_sink = sys.argv[2]
message_sent = False
message_recieved = False
complete = False

def on_message_source(_mqttc, obj, msg):
    global message_sent
    global msg_sink
    print('Source message')
    url = msg.topic.split('/')
    if url[0] == 'send' and url[1] == 'message' and url[2] == msg_sink:
        message_sent = True
    return

def on_message_sink(_mqttc, obj, msg):
    global message_recieved
    global msg_sink
    print('Sink message')
    url = msg.topic.split('/')
    if url[0] == 'send' and url[1] == 'message' and url[2] == msg_sink:
        message_recieved = True
    return

time.sleep(10)
print('Connecting to mqtt brokers: '+msg_source+' and '+msg_sink)
source_mqttc = mqtt.Client("source_client")
source_mqttc.on_message = on_message_source

source_mqttc.connect(host=msg_source, port=1883, keepalive=60)
source_mqttc.subscribe('send/message/'+msg_sink, 0)

sink_mqttc = mqtt.Client("sink_client")
sink_mqttc.on_message = on_message_sink

sink_mqttc.connect(host=msg_sink, port=1883, keepalive=60)
sink_mqttc.subscribe('send/message/'+msg_sink, 0)

source_mqttc.loop_start()
sink_mqttc.loop_start()

time.sleep(10)

timeout = 30.0 # in seconds
t0 = time.time()
print('Running tests with timeout='+str(timeout))
while not complete and time.time() - t0 < timeout:
    if not message_sent:
        print('Sending message')
        publish.single('message/'+msg_sink, payload= "this is a test message", hostname=msg_source)
    if message_sent and message_recieved:
        print('Test completed')
        complete = True
    time.sleep(1)
t1 = time.time()

if complete:
    print('Test passed in '+str(t1-t0)+' seconds')
else:
    print('Test failed: timeout')

source_mqttc.loop_stop()
sink_mqttc.loop_stop()
